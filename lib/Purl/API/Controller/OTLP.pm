package Purl::API::Controller::OTLP;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);
use Time::HiRes qw(time);

use Purl::Util::Time qw(epoch_to_iso);

extends 'Purl::API::Controller::Base';
with 'Purl::API::Controller::IngestBackpressure';

# ============================================
# OTLP JSON log ingest endpoint
# Accepts OpenTelemetry OTLP/JSON log format
# and converts to Purl internal format.
# ============================================

sub ingest {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $resource_logs = $body->{resourceLogs};
        unless ($resource_logs && ref $resource_logs eq 'ARRAY') {
            $self->render_error($c, 'Invalid OTLP format: missing resourceLogs array', 400);
            return;
        }

        my @logs;

        for my $rl (@$resource_logs) {
            my $resource_attrs = $rl->{resource}{attributes} // [];
            my $service_name = _extract_attribute($resource_attrs, 'service.name') // 'unknown';
            my $resource_host = _extract_attribute($resource_attrs, 'host.name');
            my $resource_hash = _attributes_to_hash($resource_attrs);

            my $scope_logs = $rl->{scopeLogs} // [];
            for my $sl (@$scope_logs) {
                my $log_records = $sl->{logRecords} // [];
                for my $record (@$log_records) {
                    my $log_attrs = $record->{attributes} // [];
                    my $log_host = _extract_attribute($log_attrs, 'host.name')
                        // $resource_host
                        // 'unknown';

                    # Build merged metadata from resource + log attributes
                    my $meta = { %$resource_hash, %{ _attributes_to_hash($log_attrs) } };

                    # Remove keys already promoted to top-level fields
                    delete $meta->{'service.name'};
                    delete $meta->{'host.name'};

                    # Add trace/span context if present
                    $meta->{trace_id} = $record->{traceId} if $record->{traceId};
                    $meta->{span_id}  = $record->{spanId}  if $record->{spanId};

                    my $timestamp = _nano_to_iso($record->{timeUnixNano} // $record->{observedTimeUnixNano});
                    $timestamp //= epoch_to_iso(time());

                    my $message = _extract_body($record->{body});
                    my $level   = $record->{severityText} // _severity_number_to_text($record->{severityNumber}) // 'INFO';

                    push @logs, {
                        timestamp => $timestamp,
                        level     => uc($level),
                        message   => $message,
                        service   => $service_name,
                        host      => $log_host,
                        meta      => $meta,
                        raw       => encode_json($record),
                    };
                }
            }
        }

        unless (@logs) {
            $self->render_error($c, 'No log records found in OTLP payload', 400);
            return;
        }

        if (scalar(@logs) > 10_000) {
            $self->render_error($c, 'Batch too large: maximum 10000 logs per request', 400);
            return;
        }

        # Run logs through configured pipelines (enrich / rewrite / drop)
        # before storage. No-op unless pipelines are configured.
        @logs = @{ $self->apply_pipelines($c, \@logs) };
        return if $self->reject_when_buffer_full($c, scalar @logs);

        # Field length validation and insert (same limits as Logs controller)
        my $count = 0;
        for my $log (@logs) {
            if (defined $log->{message} && length($log->{message}) > 65536) {
                $log->{message} = substr($log->{message}, 0, 65536);
            }
            if (defined $log->{service} && length($log->{service}) > 256) {
                $log->{service} = substr($log->{service}, 0, 256);
            }
            if (defined $log->{host} && length($log->{host}) > 256) {
                $log->{host} = substr($log->{host}, 0, 256);
            }
            if (defined $log->{raw} && length($log->{raw}) > 131072) {
                $log->{raw} = substr($log->{raw}, 0, 131072);
            }

            $self->storage->insert($log);
            $count++;
        }

        $self->storage->flush() if $self->storage->can('flush');

        $c->render(json => {
            status   => 'ok',
            inserted => $count,
        });
    });
}

# ============================================
# OTLP value extraction helpers
# ============================================

# Extract a typed value from an OTLP AnyValue object.
# Handles: stringValue, intValue, doubleValue, boolValue,
#           arrayValue, kvlistValue, bytesValue.
sub _extract_otlp_value {
    my ($value_obj) = @_;
    return '' unless $value_obj && ref $value_obj eq 'HASH';

    return $value_obj->{stringValue}  if exists $value_obj->{stringValue};
    return $value_obj->{intValue}     if exists $value_obj->{intValue};
    return $value_obj->{doubleValue}  if exists $value_obj->{doubleValue};
    return $value_obj->{bytesValue}   if exists $value_obj->{bytesValue};

    if (exists $value_obj->{boolValue}) {
        return $value_obj->{boolValue} ? 'true' : 'false';
    }

    if (exists $value_obj->{arrayValue}) {
        my $values = $value_obj->{arrayValue}{values} // [];
        return encode_json([ map { _extract_otlp_value($_) } @$values ]);
    }

    if (exists $value_obj->{kvlistValue}) {
        my $kvs = $value_obj->{kvlistValue}{values} // [];
        my %hash;
        for my $kv (@$kvs) {
            $hash{ $kv->{key} } = _extract_otlp_value($kv->{value}) if $kv->{key};
        }
        return encode_json(\%hash);
    }

    return '';
}

# Find a specific attribute by key in an OTLP attributes array.
# Returns the extracted value or undef if not found.
sub _extract_attribute {
    my ($attrs, $key) = @_;
    return undef unless $attrs && ref $attrs eq 'ARRAY';

    for my $attr (@$attrs) {
        if ($attr->{key} && $attr->{key} eq $key) {
            return _extract_otlp_value($attr->{value});
        }
    }
    return undef;
}

# Convert an OTLP attributes array to a flat key-value hash.
sub _attributes_to_hash {
    my ($attrs) = @_;
    return {} unless $attrs && ref $attrs eq 'ARRAY';

    my %hash;
    for my $attr (@$attrs) {
        next unless $attr->{key};
        $hash{ $attr->{key} } = _extract_otlp_value($attr->{value});
    }
    return \%hash;
}

# Extract the log body text from an OTLP AnyValue body.
sub _extract_body {
    my ($body) = @_;
    return '' unless $body;

    # Body can be a simple AnyValue
    if (ref $body eq 'HASH') {
        return _extract_otlp_value($body);
    }

    # Fallback: treat as plain string
    return "$body";
}

# Convert nanosecond Unix timestamp to ISO8601.
# OTLP sends timeUnixNano as a string (uint64).
sub _nano_to_iso {
    my ($nano_str) = @_;
    return undef unless defined $nano_str && $nano_str =~ /^\d+$/;

    # Convert nanoseconds to seconds (integer division)
    my $epoch_secs = int($nano_str / 1_000_000_000);
    return epoch_to_iso($epoch_secs);
}

# Map OTLP severity number to text when severityText is absent.
# See: https://opentelemetry.io/docs/specs/otel/logs/data-model/#severity-fields
sub _severity_number_to_text {
    my ($num) = @_;
    return undef unless defined $num;

    return 'TRACE' if $num >= 1  && $num <= 4;
    return 'DEBUG' if $num >= 5  && $num <= 8;
    return 'INFO'  if $num >= 9  && $num <= 12;
    return 'WARN'  if $num >= 13 && $num <= 16;
    return 'ERROR' if $num >= 17 && $num <= 20;
    return 'FATAL' if $num >= 21 && $num <= 24;
    return 'INFO';
}

1;

__END__

=head1 NAME

Purl::API::Controller::OTLP - OpenTelemetry OTLP/JSON log ingest

=head1 DESCRIPTION

Accepts OpenTelemetry log data in OTLP/JSON format and converts it to
Purl's internal log format for storage in ClickHouse.

Endpoint: POST /api/v1/otlp/logs

=head1 OTLP FORMAT

The endpoint expects the standard OTLP JSON encoding with resourceLogs,
scopeLogs, and logRecords. See:
L<https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding>

=cut

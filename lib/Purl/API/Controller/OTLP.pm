package Purl::API::Controller::OTLP;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();

extends 'Purl::API::Controller::Base';

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical->allow_nonref },
);

# Span kind mapping (OTLP uses integers)
my %SPAN_KINDS = (
    0 => 'UNSPECIFIED',
    1 => 'INTERNAL',
    2 => 'SERVER',
    3 => 'CLIENT',
    4 => 'PRODUCER',
    5 => 'CONSUMER',
);

# Status code mapping
my %STATUS_CODES = (
    0 => 'UNSET',
    1 => 'OK',
    2 => 'ERROR',
);

# POST /v1/traces - OTLP trace receiver
sub receive_traces {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $data = $c->req->json;

        unless ($data) {
            $self->render_error($c, 'Invalid JSON body', 400);
            return;
        }

        my @spans = $self->_extract_spans($data);

        if (@spans) {
            eval {
                $self->storage->insert_spans(\@spans);
            };
            if ($@) {
                warn "OTLP insert error: $@";
                # Still return success to not break exporters
            }
        }

        # OTLP spec: return empty object on success
        $c->render(json => {});
    });
}

# POST /v1/metrics - OTLP metrics receiver (accept but ignore for now)
sub receive_metrics {
    my ($self, $c) = @_;

    # Accept metrics but don't process them yet
    $c->render(json => {});
}

# POST /v1/logs - OTLP logs receiver (forward to existing log ingestion)
sub receive_logs {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $data = $c->req->json;

        unless ($data) {
            $self->render_error($c, 'Invalid JSON body', 400);
            return;
        }

        my @logs = $self->_extract_logs($data);

        if (@logs) {
            eval {
                $self->storage->insert_batch(\@logs);
            };
            if ($@) {
                warn "OTLP logs insert error: $@";
            }
        }

        $c->render(json => {});
    });
}

# Extract spans from OTLP ResourceSpans structure
sub _extract_spans {
    my ($self, $data) = @_;
    my @spans;

    # OTLP structure: resourceSpans[].scopeSpans[].spans[]
    for my $rs (@{$data->{resourceSpans} // []}) {
        my $resource = $rs->{resource} // {};
        my $service_name = $self->_get_service_name($resource);
        my $resource_attrs = $self->_json->encode($resource->{attributes} // []);

        for my $ss (@{$rs->{scopeSpans} // []}) {
            for my $span (@{$ss->{spans} // []}) {
                my $span_kind = $SPAN_KINDS{$span->{kind} // 0} // 'INTERNAL';
                my $status_code = 'UNSET';
                my $status_message = '';

                if (my $status = $span->{status}) {
                    $status_code = $STATUS_CODES{$status->{code} // 0} // 'UNSET';
                    $status_message = $status->{message} // '';
                }

                # Convert string timestamps to integers (OTLP sends them as strings)
                my $start_ns = int($span->{startTimeUnixNano} // 0);
                my $end_ns = int($span->{endTimeUnixNano} // $start_ns);

                push @spans, {
                    trace_id           => $span->{traceId} // '',
                    span_id            => $span->{spanId} // '',
                    parent_span_id     => $span->{parentSpanId} // '',
                    start_time         => $start_ns,
                    end_time           => $end_ns,
                    service            => $service_name,
                    operation          => $span->{name} // '',
                    span_kind          => $span_kind,
                    status_code        => $status_code,
                    status_message     => $status_message,
                    attributes         => $self->_json->encode($span->{attributes} // []),
                    resource_attributes => $resource_attrs,
                    events             => $self->_json->encode($span->{events} // []),
                };
            }
        }
    }

    return @spans;
}

# Extract logs from OTLP ResourceLogs structure
sub _extract_logs {
    my ($self, $data) = @_;
    my @logs;

    # OTLP structure: resourceLogs[].scopeLogs[].logRecords[]
    for my $rl (@{$data->{resourceLogs} // []}) {
        my $resource = $rl->{resource} // {};
        my $service_name = $self->_get_service_name($resource);

        for my $sl (@{$rl->{scopeLogs} // []}) {
            for my $log (@{$sl->{logRecords} // []}) {
                my $level = $self->_severity_to_level($log->{severityNumber} // 0);
                my $timestamp = $self->_ns_to_iso($log->{timeUnixNano} // 0);

                push @logs, {
                    timestamp  => $timestamp,
                    level      => $level,
                    service    => $service_name,
                    host       => 'otlp',
                    message    => $log->{body}{stringValue} // '',
                    raw        => $log->{body}{stringValue} // '',
                    meta       => {},
                    trace_id   => $log->{traceId} // '',
                    span_id    => $log->{spanId} // '',
                };
            }
        }
    }

    return @logs;
}

# Get service name from resource attributes
sub _get_service_name {
    my ($self, $resource) = @_;

    for my $attr (@{$resource->{attributes} // []}) {
        if ($attr->{key} eq 'service.name') {
            return $attr->{value}{stringValue} // 'unknown';
        }
    }

    return 'unknown';
}

# Convert OTLP severity number to log level
sub _severity_to_level {
    my ($self, $severity) = @_;

    return 'TRACE' if $severity <= 4;
    return 'DEBUG' if $severity <= 8;
    return 'INFO'  if $severity <= 12;
    return 'WARN'  if $severity <= 16;
    return 'ERROR' if $severity <= 20;
    return 'FATAL' if $severity <= 24;
    return 'INFO';
}

# Convert nanoseconds to ISO timestamp
sub _ns_to_iso {
    my ($self, $ns) = @_;
    return undef unless $ns && $ns > 0;

    my $sec = int($ns / 1_000_000_000);
    my $ms = int(($ns % 1_000_000_000) / 1_000_000);

    my @t = gmtime($sec);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ',
        $t[5] + 1900, $t[4] + 1, $t[3],
        $t[2], $t[1], $t[0], $ms
    );
}

1;

__END__

=head1 NAME

Purl::API::Controller::OTLP - OpenTelemetry Protocol (OTLP) receiver

=head1 SYNOPSIS

    # Receive traces from OpenTelemetry exporters
    POST /v1/traces
    Content-Type: application/json

    # Receive logs from OpenTelemetry exporters
    POST /v1/logs
    Content-Type: application/json

=head1 DESCRIPTION

This controller implements OTLP HTTP/JSON endpoints for receiving
telemetry data from OpenTelemetry-compatible exporters like Grafana Beyla.

=head1 ENDPOINTS

=over 4

=item POST /v1/traces

Receives trace spans in OTLP JSON format and stores them in ClickHouse.

=item POST /v1/metrics

Accepts metrics but currently ignores them (placeholder for future).

=item POST /v1/logs

Receives logs in OTLP format and stores them in the logs table.

=back

=cut

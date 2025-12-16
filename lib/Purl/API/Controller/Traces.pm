package Purl::API::Controller::Traces;
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

# List recent traces (from real spans)
sub list_traces {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $range   = $c->param('range') // '1h';
        my $limit   = $c->param('limit') // 50;
        my $service = $c->param('service');

        my %params = (
            range => $range,
            limit => int($limit),
        );
        $params{service} = $service if $service;

        # Try to get traces from spans table first
        my $result = eval { $self->storage->list_traces_from_spans(%params) };

        # Fallback to log-based traces if spans table empty or error
        if ($@ || !$result || !$result->{traces} || @{$result->{traces}} == 0) {
            $result = $self->storage->list_recent_traces(%params);
        }

        $c->render(json => {
            traces  => $result->{traces} // [],
            total   => $result->{total} // 0,
            service => $service,
        });
    });
}

# Get trace details - returns spans if available, logs as fallback
sub get_trace {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $trace_id = $c->param('trace_id');
        my $limit    = $c->param('limit') // 200;

        unless ($trace_id && $trace_id =~ /^[a-fA-F0-9\-]{8,64}$/) {
            $self->render_error($c, 'Invalid trace ID format', 400);
            return;
        }

        # Try to get spans first
        my $spans = eval { $self->storage->get_trace_spans($trace_id) };

        if ($spans && @$spans > 0) {
            # Return real spans
            my @formatted = map {
                my $attrs = eval { $self->_json->decode($_->{attributes} // '[]') } // [];
                my $events = eval { $self->_json->decode($_->{events} // '[]') } // [];
                {
                    span_id        => $_->{span_id},
                    parent_span_id => $_->{parent_span_id},
                    service        => $_->{service},
                    operation      => $_->{operation},
                    span_kind      => $_->{span_kind},
                    start_time     => $_->{start_time},
                    end_time       => $_->{end_time},
                    duration_ms    => $_->{duration_ns} ? $_->{duration_ns} / 1_000_000 : 0,
                    status_code    => $_->{status_code},
                    status_message => $_->{status_message},
                    attributes     => $attrs,
                    events         => $events,
                }
            } @$spans;

            $c->render(json => {
                trace_id => lc($trace_id),
                spans    => \@formatted,
                total    => scalar(@formatted),
                source   => 'spans',
            });
            return;
        }

        # Fallback to logs
        my $result = $self->storage->search_by_trace($trace_id, limit => int($limit));

        unless ($result->{total} > 0) {
            $self->render_error($c, 'Trace not found', 404);
            return;
        }

        $c->render(json => {
            trace_id => lc($trace_id),
            hits     => $result->{hits},
            total    => $result->{total},
            source   => 'logs',
        });
    });
}

# Get trace timeline - waterfall view
sub get_trace_timeline {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $trace_id = $c->param('trace_id');

        unless ($trace_id && $trace_id =~ /^[a-fA-F0-9\-]{8,64}$/) {
            $self->render_error($c, 'Invalid trace ID format', 400);
            return;
        }

        # Try to get real spans first
        my $spans = eval { $self->storage->get_trace_spans($trace_id) };

        if ($spans && @$spans > 0) {
            # Build timeline from real spans
            my @timeline;
            my $min_start;
            my $max_end;

            for my $span (@$spans) {
                my $duration_ms = $span->{duration_ns} ? $span->{duration_ns} / 1_000_000 : 0;

                push @timeline, {
                    span_id        => $span->{span_id},
                    parent_span_id => $span->{parent_span_id},
                    service        => $span->{service},
                    operation      => $span->{operation},
                    span_kind      => $span->{span_kind},
                    start_time     => $span->{start_time},
                    end_time       => $span->{end_time},
                    duration_ms    => $duration_ms,
                    status_code    => $span->{status_code},
                };

                $min_start //= $span->{start_time};
                $max_end //= $span->{end_time};
                $min_start = $span->{start_time} if $span->{start_time} lt $min_start;
                $max_end = $span->{end_time} if $span->{end_time} gt $max_end;
            }

            $c->render(json => {
                trace_id   => lc($trace_id),
                services   => \@timeline,
                start_time => $min_start,
                end_time   => $max_end,
                source     => 'spans',
            });
            return;
        }

        # Fallback to log-based timeline
        my $timeline = $self->storage->get_trace_timeline($trace_id);

        unless (@$timeline) {
            $self->render_error($c, 'Trace not found', 404);
            return;
        }

        my $first_start = $timeline->[0]{start_time};
        my $last_end = $timeline->[-1]{end_time};

        $c->render(json => {
            trace_id   => lc($trace_id),
            services   => $timeline,
            start_time => $first_start,
            end_time   => $last_end,
            source     => 'logs',
        });
    });
}

# Get logs by request ID (existing functionality)
sub get_request {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $request_id = $c->param('request_id');
        my $limit      = $c->param('limit') // 200;

        unless ($request_id && $request_id =~ /^[a-fA-F0-9\-]{8,36}$/) {
            $self->render_error($c, 'Invalid request ID format', 400);
            return;
        }

        my $result = $self->storage->search_by_request($request_id, limit => int($limit));

        unless ($result->{total} > 0) {
            $self->render_error($c, 'Request not found', 404);
            return;
        }

        $c->render(json => {
            request_id => lc($request_id),
            hits       => $result->{hits},
            total      => $result->{total},
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Traces - Trace correlation API

=head1 DESCRIPTION

Handles trace-related API endpoints. Supports both real OTLP spans
(from Beyla/OpenTelemetry) and log-based trace correlation.

=head1 ENDPOINTS

=over 4

=item GET /api/traces

List recent traces with their services and durations.

=item GET /api/traces/:trace_id

Get trace details - returns spans if available, otherwise logs.

=item GET /api/traces/:trace_id/timeline

Get trace timeline for waterfall visualization.

=item GET /api/requests/:request_id

Get logs by request ID.

=back

=cut

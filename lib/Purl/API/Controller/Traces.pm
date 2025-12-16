package Purl::API::Controller::Traces;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

extends 'Purl::API::Controller::Base';

sub list_traces {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $range = $c->param('range') // '1h';
        my $limit = $c->param('limit') // 50;

        my $result = $self->storage->list_recent_traces(
            range => $range,
            limit => int($limit),
        );

        $c->render(json => {
            traces => $result->{traces},
            total  => $result->{total},
        });
    });
}

sub get_trace {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $trace_id = $c->param('trace_id');
        my $limit    = $c->param('limit') // 200;

        unless ($trace_id && $trace_id =~ /^[a-fA-F0-9\-]{8,36}$/) {
            $self->render_error($c, 'Invalid trace ID format', 400);
            return;
        }

        # Check existing method in storage
        my $result = $self->storage->search_by_trace($trace_id, limit => int($limit));

        unless ($result->{total} > 0) {
            $self->render_error($c, 'Trace not found', 404);
            return;
        }

        $c->render(json => {
            trace_id => lc($trace_id),
            hits     => $result->{hits},
            total    => $result->{total},
        });
    });
}

sub get_trace_timeline {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $trace_id = $c->param('trace_id');

        unless ($trace_id && $trace_id =~ /^[a-fA-F0-9\-]{8,36}$/) {
            $self->render_error($c, 'Invalid trace ID format', 400);
            return;
        }

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
        });
    });
}

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

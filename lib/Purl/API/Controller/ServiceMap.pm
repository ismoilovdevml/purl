package Purl::API::Controller::ServiceMap;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

extends 'Purl::API::Controller::Base';

# ============================================
# Service Map Endpoints
# ============================================

# GET /api/services - List all services with health
sub list_services {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $from = $c->param('from');
        my $to   = $c->param('to');

        # Parse time range
        if (my $range = $c->param('range')) {
            require Purl::Utils::Time;
            ($from, $to) = Purl::Utils::Time::parse_time_range($range);
        }

        my %params;
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        # Check cache
        my $cache_key = "services:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $services = $self->storage->get_services(%params);
        my $health = $self->storage->get_service_health(%params);

        # Merge health data
        my %health_map = map { $_->{service} => $_ } @$health;
        for my $svc (@$services) {
            my $h = $health_map{$svc->{service}} // {};
            $svc->{error_rate} = $h->{error_rate} // 0;
            $svc->{health_status} = $h->{health_status} // 'unknown';
        }

        my $response = {
            services => $services,
            total => scalar(@$services),
        };

        $self->set_cached($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $response);
    });
}

# GET /api/services/dependencies - Get service dependency graph
sub get_dependencies {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $from = $c->param('from');
        my $to   = $c->param('to');

        if (my $range = $c->param('range')) {
            require Purl::Utils::Time;
            ($from, $to) = Purl::Utils::Time::parse_time_range($range);
        }

        my %params;
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $cache_key = "dependencies:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $edges = $self->storage->get_service_dependencies(%params);
        my $services = $self->storage->get_services(%params);

        # Build graph structure for Cytoscape
        my @nodes = map {{
            data => {
                id => $_->{service},
                label => $_->{service},
                log_count => $_->{log_count},
                error_count => $_->{error_count},
            }
        }} @$services;

        my @graph_edges = map {{
            data => {
                id => "$_->{source_service}-$_->{target_service}",
                source => $_->{source_service},
                target => $_->{target_service},
                call_count => $_->{call_count},
                error_count => $_->{error_count},
                avg_duration_ms => $_->{avg_duration_ms} // 0,
            }
        }} @$edges;

        my $response = {
            nodes => \@nodes,
            edges => \@graph_edges,
            raw_edges => $edges,
            total_services => scalar(@$services),
            total_edges => scalar(@$edges),
        };

        $self->set_cached($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $response);
    });
}

# GET /api/services/:name - Get service details
sub get_service {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $name = $c->param('name');
        my $range = $c->param('range') // '1h';

        unless ($name) {
            $self->render_error($c, 'Service name required', 400);
            return;
        }

        my $details = $self->storage->get_service_details($name, from => $range);

        $c->render(json => $details);
    });
}

# GET /api/services/:name/upstream - Get upstream services
sub get_upstream {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $name = $c->param('name');

        unless ($name) {
            $self->render_error($c, 'Service name required', 400);
            return;
        }

        my $upstream = $self->storage->get_upstream_services($name);

        $c->render(json => {
            service => $name,
            upstream => $upstream,
            total => scalar(@$upstream),
        });
    });
}

# GET /api/services/:name/downstream - Get downstream services
sub get_downstream {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $name = $c->param('name');

        unless ($name) {
            $self->render_error($c, 'Service name required', 400);
            return;
        }

        my $downstream = $self->storage->get_downstream_services($name);

        $c->render(json => {
            service => $name,
            downstream => $downstream,
            total => scalar(@$downstream),
        });
    });
}

# GET /api/services/health - Get all services health
sub get_health {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $from = $c->param('from');
        my $to   = $c->param('to');

        if (my $range = $c->param('range')) {
            require Purl::Utils::Time;
            ($from, $to) = Purl::Utils::Time::parse_time_range($range);
        }

        my %params;
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $cache_key = "health:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $health = $self->storage->get_service_health(%params);

        my $response = {
            services => $health,
            total => scalar(@$health),
            summary => {
                healthy => scalar(grep { $_->{health_status} eq 'healthy' } @$health),
                degraded => scalar(grep { $_->{health_status} eq 'degraded' } @$health),
                critical => scalar(grep { $_->{health_status} eq 'critical' } @$health),
            },
        };

        $self->set_cached($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $response);
    });
}

# GET /api/services/:name/metrics - Get service metrics timeseries
sub get_metrics {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $name = $c->param('name');
        my $range = $c->param('range') // '1h';
        my $interval = $c->param('interval') // '1minute';

        unless ($name) {
            $self->render_error($c, 'Service name required', 400);
            return;
        }

        my $timeseries = $self->storage->get_service_metrics_timeseries(
            $name,
            range => $range,
            interval => $interval
        );

        $c->render(json => {
            service => $name,
            range => $range,
            interval => $interval,
            data => $timeseries,
            total_points => scalar(@$timeseries),
        });
    });
}

# GET /api/services/:name/latency - Get service latency metrics
sub get_latency {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $name = $c->param('name');
        my $range = $c->param('range') // '1h';
        my $interval = $c->param('interval') // '1minute';

        unless ($name) {
            $self->render_error($c, 'Service name required', 400);
            return;
        }

        my $percentiles = $self->storage->get_service_latency_percentiles(
            $name,
            range => $range
        );

        my $timeseries = $self->storage->get_service_latency_timeseries(
            $name,
            range => $range,
            interval => $interval
        );

        $c->render(json => {
            service => $name,
            range => $range,
            percentiles => $percentiles,
            timeseries => $timeseries,
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::ServiceMap - Service Map API Controller

=head1 ENDPOINTS

    GET /api/services                    - List all services
    GET /api/services/dependencies       - Get dependency graph
    GET /api/services/health            - Get health status
    GET /api/services/:name             - Get service details
    GET /api/services/:name/upstream    - Get upstream dependencies
    GET /api/services/:name/downstream  - Get downstream dependencies

=cut

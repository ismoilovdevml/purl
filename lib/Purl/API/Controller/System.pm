package Purl::API::Controller::System;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Time::HiRes qw(time);

extends 'Purl::API::Controller::Base';

# Version constant
our $VERSION = '1.2.0';

sub health {
    my ($self, $c) = @_;
    
    # Eval DB check
    my $ch_ok = eval { $self->storage->stats(); 1 };
    my $ch_error = $@;
    $ch_ok //= 0;

    if ($ch_error) {
        $c->app->log->warn("Health check - ClickHouse error: $ch_error");
    }

    my $status = $ch_ok ? 'ok' : 'degraded';
    my $code = $ch_ok ? 200 : 503;
    
    # Calculate uptime if start_time is available in app or stashed?
    # We can pass start_time in config or use $^T
    my $start_time = $^T; 

    $c->render(json => {
        status      => $status,
        timestamp   => time(),
        version     => $VERSION,
        clickhouse  => $ch_ok ? 'connected' : 'disconnected',
        uptime_secs => int(time() - $start_time),
        ($ch_error ? (error => substr($ch_error, 0, 200)) : ()),
    }, status => $code);
}

sub metrics {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $stats = eval { $self->storage->stats() } // {};
        my $start_time = $^T;
        my $uptime = int(time() - $start_time);
        
        # We don't have access to global %metrics from Server.pm easily here unless passed
        # For now, we output what we can from storage and system
        
        my $output = <<"METRICS";
# HELP purl_info Purl server information
# TYPE purl_info gauge
purl_info{version="$VERSION"} 1

# HELP purl_uptime_seconds Server uptime in seconds
# TYPE purl_uptime_seconds counter
purl_uptime_seconds $uptime

# HELP purl_logs_stored Total logs in storage
# TYPE purl_logs_stored gauge
purl_logs_stored $stats->{total_logs}

# HELP purl_db_size_bytes Database size in bytes
# TYPE purl_db_size_bytes gauge
purl_db_size_bytes $stats->{db_size_bytes}

# HELP purl_cache_size Cache entries count
# TYPE purl_cache_size gauge
purl_cache_size @{[scalar keys %{$self->cache}]}
METRICS

        $c->render(text => $output, format => 'txt');
    });
}

sub metrics_json {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $stats = eval { $self->storage->stats() } // {};
        my $ch_metrics = eval { $self->storage->get_metrics() } // {};
        my $uptime = int(time() - $^T);

        $c->render(json => {
            server => {
                version       => $VERSION,
                uptime_secs   => $uptime,
            },
            storage => {
                total_logs    => $stats->{total_logs} // 0,
                db_size_mb    => $stats->{db_size_mb} // 0,
                oldest_log    => $stats->{oldest_log},
                newest_log    => $stats->{newest_log},
            },
            clickhouse => {
                queries_total   => $ch_metrics->{queries_total} // 0,
                queries_cached  => $ch_metrics->{queries_cached} // 0,
                cache_hit_rate  => $ch_metrics->{cache_hit_rate} // '0%',
                avg_query_time  => $ch_metrics->{avg_query_time} // '0s',
                inserts_total   => $ch_metrics->{inserts_total} // 0,
                bytes_inserted  => $ch_metrics->{bytes_inserted} // 0,
                buffer_size     => $ch_metrics->{buffer_size} // 0,
                errors_total    => $ch_metrics->{errors_total} // 0,
            },
            cache => {
                entries       => scalar keys %{$self->cache},
            },
        });
    });
}

1;

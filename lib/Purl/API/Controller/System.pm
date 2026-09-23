package Purl::API::Controller::System;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(classify_error);
use namespace::clean;
use Time::HiRes qw(time);
use Purl::Metrics::Prometheus;

extends 'Purl::API::Controller::Base';

# Version constant
our $VERSION = '1.3.0';

# Cross-worker Prometheus counters (Purl::Metrics::Counters). Optional: when
# absent the exporter still renders, just with zeroed request counters.
has 'metrics_counters' => (
    is      => 'ro',
    default => sub { undef },
);

# One ClickHouse probe, used by /api/health and /api/health/ready. Returns
# (ok, public_error). These endpoints are UNAUTHENTICATED, so the raw
# exception (ClickHouse text, file/line) goes to the log only and the body gets
# the classified, fixed message (#107).
sub _clickhouse_probe {
    my ($self, $c) = @_;
    my $ok = eval { $self->storage->stats(); 1 } // 0;
    return (1, undef) if $ok;
    my $error = $@ || 'unknown error';
    $c->app->log->warn("Health check - ClickHouse error: $error");
    my (undef, $public) = classify_error($error);
    return (0, $public);
}

# Legacy combined endpoint. Behaviour deliberately UNCHANGED (200 when
# ClickHouse answers, 503 otherwise) — external monitors and the dashboard
# already depend on it. New deployments should use /live and /ready.
sub health {
    my ($self, $c) = @_;

    my ($ch_ok, $ch_error) = $self->_clickhouse_probe($c);

    my $status = $ch_ok ? 'ok' : 'degraded';
    my $code = $ch_ok ? 200 : 503;

    my $cb_status = eval { $self->storage->circuit_breaker_status() } // {};

    $c->render(json => {
        status      => $status,
        timestamp   => time(),
        version     => $VERSION,
        clickhouse  => $ch_ok ? 'connected' : 'disconnected',
        circuit_breaker => $cb_status,
        uptime_secs => int(time() - $^T),
        ($ch_error ? (error => $ch_error) : ()),
    }, status => $code);
}

# LIVENESS: is this process running and able to serve? Deliberately touches
# NOTHING external.
#
# Wiring a k8s livenessProbe to a database-dependent endpoint means a
# ClickHouse outage makes the kubelet kill every Purl pod, turning a recoverable
# dependency failure into a cluster-wide CrashLoopBackOff that cannot recover
# even after the database comes back. Liveness must only answer "is this
# process wedged?".
sub health_live {
    my ($self, $c) = @_;

    $c->render(json => {
        status      => 'ok',
        timestamp   => time(),
        version     => $VERSION,
        uptime_secs => int(time() - $^T),
    }, status => 200);
}

# READINESS: should this instance receive traffic? Requires ClickHouse.
# Failing readiness pulls the pod out of the Service endpoints without
# restarting it, so it rejoins automatically once the database recovers.
sub health_ready {
    my ($self, $c) = @_;

    my ($ch_ok, $ch_error) = $self->_clickhouse_probe($c);
    my $cb_status = eval { $self->storage->circuit_breaker_status() } // {};

    $c->render(json => {
        status      => $ch_ok ? 'ok' : 'unready',
        timestamp   => time(),
        version     => $VERSION,
        clickhouse  => $ch_ok ? 'connected' : 'disconnected',
        circuit_breaker => $cb_status,
        uptime_secs => int(time() - $^T),
        ($ch_error ? (error => $ch_error) : ()),
    }, status => $ch_ok ? 200 : 503);
}

sub metrics {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # A failed stats() call is NOT an error here — it is the signal for
        # purl_clickhouse_healthy 0. The scrape must still succeed, otherwise
        # the outage takes the metrics down with it.
        my $stats = eval { $self->storage->stats() };
        my $ch_ok = ($stats && !$@) ? 1 : 0;

        my $snapshot = $self->metrics_counters
            ? $self->metrics_counters->snapshot
            : {};

        my $output = Purl::Metrics::Prometheus::render(
            version            => $VERSION,
            uptime_seconds     => int(time() - $^T),
            clickhouse_healthy => $ch_ok,
            stats              => $stats // {},
            cache_size         => scalar keys %{ $self->cache },
            counters           => $snapshot,
        );

        $c->render(text => $output, format => 'txt');
    });
}

sub metrics_json {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $stats = eval { $self->storage->stats() } // {};
        my $ch_metrics = eval { $self->storage->get_metrics() } // {};
        my $server_metrics = Purl::API::Server::get_metrics();

        my $uptime_secs = int(time() - ($server_metrics->{start_time} // $^T));
        my $uptime_human = _format_uptime($uptime_secs);

        # Calculate percentiles from latencies
        my @latencies = sort { $a <=> $b } @{$server_metrics->{latencies} // []};
        my $p50 = _percentile(\@latencies, 50);
        my $p95 = _percentile(\@latencies, 95);
        my $p99 = _percentile(\@latencies, 99);
        my $max_latency = @latencies ? $latencies[-1] : 0;

        # Calculate requests per second
        my $rps = $uptime_secs > 0
            ? sprintf("%.1f", ($server_metrics->{requests_total} // 0) / $uptime_secs)
            : 0;

        $c->render(json => {
            server => {
                version       => $VERSION,
                uptime_secs   => $uptime_secs,
                uptime_human  => $uptime_human,
            },
            storage => {
                total_logs    => $stats->{total_logs} // 0,
                db_size_mb    => $stats->{db_size_mb} // 0,
                db_size_bytes => $stats->{db_size_bytes} // 0,
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
            requests => {
                total         => $server_metrics->{requests_total} // 0,
                errors        => $server_metrics->{errors_total} // 0,
                per_second    => $rps,
                bytes_in      => $server_metrics->{bytes_in} // 0,
                bytes_out     => $server_metrics->{bytes_out} // 0,
                p50_latency   => sprintf("%.1fms", $p50),
                p95_latency   => sprintf("%.1fms", $p95),
                p99_latency   => sprintf("%.1fms", $p99),
                max_latency   => sprintf("%.1fms", $max_latency),
            },
            cache => {
                entries       => scalar keys %{$self->cache},
                ttl           => '60s',
                hit_rate      => $ch_metrics->{cache_hit_rate} // '0%',
            },
        });
    });
}

sub _percentile {
    my ($sorted_arr, $p) = @_;
    return 0 unless @$sorted_arr;
    my $idx = int(($p / 100) * @$sorted_arr);
    $idx = @$sorted_arr - 1 if $idx >= @$sorted_arr;
    return $sorted_arr->[$idx];
}

sub _format_uptime {
    my ($secs) = @_;
    if ($secs < 60) {
        return "${secs}s";
    } elsif ($secs < 3600) {
        return sprintf("%dm %ds", int($secs / 60), $secs % 60);
    } elsif ($secs < 86400) {
        my $h = int($secs / 3600);
        my $m = int(($secs % 3600) / 60);
        return sprintf("%dh %dm", $h, $m);
    } else {
        my $d = int($secs / 86400);
        my $h = int(($secs % 86400) / 3600);
        return sprintf("%dd %dh", $d, $h);
    }
}

1;

package Purl::Metrics::Prometheus;
use strict;
use warnings;
use 5.024;

# ============================================================================
# Purl::Metrics::Prometheus
#
# Renders the /api/metrics exposition text. One job: turning already-collected
# numbers into valid Prometheus text format.
#
# The hard rule this module exists to enforce: EVERY value must be a number.
# A single missing value (e.g. `purl_logs_stored ` when ClickHouse is down)
# makes Prometheus reject the WHOLE scrape as malformed — so the moment the
# database dies you also lose the request rate, the error rate and the
# up-ness of the exporter, which is precisely when you need them.
# ============================================================================

# Coerce anything into a Prometheus-safe number. undef, '', 'N/A' and any
# non-numeric string all become 0 rather than producing an invalid line.
sub _num {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 unless $value =~ /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/;
    return $value + 0;
}

# Escape a Prometheus label value (backslash, double quote, newline).
sub _label {
    my ($value) = @_;
    $value //= '';
    $value =~ s/\\/\\\\/g;
    $value =~ s/"/\\"/g;
    $value =~ s/\n/\\n/g;
    return $value;
}

sub _metric {
    my ($name, $help, $type, @samples) = @_;
    return join("\n",
        "# HELP $name $help",
        "# TYPE $name $type",
        @samples,
    ) . "\n";
}

# render(%args) -> exposition text
#
#   version           server version string
#   uptime_seconds    process uptime
#   clickhouse_healthy 1/0
#   stats             storage stats hashref (total_logs, db_size_bytes)
#   cache_size        controller cache entry count
#   counters          Purl::Metrics::Counters snapshot hashref
sub render {
    my (%args) = @_;

    my $version   = _label($args{version} // 'unknown');
    my $stats     = $args{stats}    // {};
    my $counters  = $args{counters} // {};
    my $out = '';

    $out .= _metric('purl_info', 'Purl server information', 'gauge',
        qq{purl_info{version="$version"} 1});
    $out .= "\n";

    $out .= _metric('purl_uptime_seconds', 'Server uptime in seconds', 'counter',
        'purl_uptime_seconds ' . _num($args{uptime_seconds}));
    $out .= "\n";

    # 0/1 up-ness of the datastore. This is the metric alerting keys off, so it
    # must be present EXACTLY when ClickHouse is broken — never omitted.
    $out .= _metric('purl_clickhouse_healthy',
        'ClickHouse reachable from this instance (1 = yes)', 'gauge',
        'purl_clickhouse_healthy ' . ($args{clickhouse_healthy} ? 1 : 0));
    $out .= "\n";

    $out .= _metric('purl_logs_stored', 'Total logs in storage', 'gauge',
        'purl_logs_stored ' . _num($stats->{total_logs}));
    $out .= "\n";

    $out .= _metric('purl_db_size_bytes', 'Database size in bytes', 'gauge',
        'purl_db_size_bytes ' . _num($stats->{db_size_bytes}));
    $out .= "\n";

    $out .= _metric('purl_cache_size', 'Cache entries count', 'gauge',
        'purl_cache_size ' . _num($args{cache_size}));
    $out .= "\n";

    # --- Request counters (labelled) ---
    my @request_samples;
    my $requests = $counters->{requests} // {};
    for my $method (sort keys %$requests) {
        for my $status (sort keys %{ $requests->{$method} }) {
            my $m = _label($method);
            my $s = _label($status);
            push @request_samples,
                qq{purl_http_requests_total{method="$m",status="$s"} }
                . _num($requests->{$method}{$status});
        }
    }
    # Always emit the metric family, even with no traffic yet: a series that
    # appears only after the first request makes every rate() query fragile.
    push @request_samples, 'purl_http_requests_total{method="none",status="none"} 0'
        unless @request_samples;

    $out .= _metric('purl_http_requests_total', 'HTTP requests by method and status',
        'counter', @request_samples);
    $out .= "\n";

    $out .= _metric('purl_errors_total', 'HTTP responses with status >= 400', 'counter',
        'purl_errors_total ' . _num($counters->{errors_total}));
    $out .= "\n";

    # Summary without quantiles: rate(sum)/rate(count) gives average latency,
    # which is what a cross-worker integer counter can honestly support.
    my $sum_seconds = _num($counters->{latency_ms_sum}) / 1000;
    $out .= _metric('purl_query_latency_seconds', 'Request handling latency', 'summary',
        sprintf('purl_query_latency_seconds_sum %.3f', $sum_seconds),
        'purl_query_latency_seconds_count ' . _num($counters->{latency_count}));
    $out .= "\n";

    $out .= _metric('purl_ingest_bytes_total', 'Bytes accepted on ingest endpoints',
        'counter',
        'purl_ingest_bytes_total ' . _num($counters->{ingest_bytes_total}));
    $out .= "\n";

    # Always present (0 when nothing was lost), so an alert on increase() works
    # from the first scrape.
    $out .= _metric('purl_ingest_dropped_total',
        'Logs accepted by ingest and then dropped before reaching ClickHouse', 'counter',
        'purl_ingest_dropped_total ' . _num($counters->{ingest_dropped_total}));
    $out .= "\n";

    # Tells the operator whether the counters above are fleet-wide or
    # per-worker — without it, a low request rate under prefork looks like a
    # traffic drop rather than an unconfigured Redis.
    $out .= _metric('purl_metrics_shared',
        'Counters are backed by a shared store across workers (1 = yes)', 'gauge',
        'purl_metrics_shared ' . ($counters->{shared} ? 1 : 0));

    return $out;
}

1;

__END__

=head1 NAME

Purl::Metrics::Prometheus - Prometheus exposition-format renderer

=head1 SYNOPSIS

    my $text = Purl::Metrics::Prometheus::render(
        version            => '1.2.0',
        uptime_seconds     => 1234,
        clickhouse_healthy => 1,
        stats              => $storage_stats,
        cache_size         => 12,
        counters           => $counters->snapshot,
    );

=head1 DESCRIPTION

Pure formatting; collects nothing itself. Every emitted value passes through a
numeric coercion so a missing or non-numeric input becomes C<0> instead of
producing a malformed line — one bad line invalidates the entire scrape.

=head1 METRICS

    purl_info{version}                          gauge
    purl_uptime_seconds                         counter
    purl_clickhouse_healthy                     gauge (0/1)
    purl_logs_stored                            gauge
    purl_db_size_bytes                          gauge
    purl_cache_size                             gauge
    purl_http_requests_total{method,status}     counter
    purl_errors_total                           counter
    purl_query_latency_seconds_{sum,count}      summary
    purl_ingest_bytes_total                     counter
    purl_ingest_dropped_total                   counter
    purl_metrics_shared                         gauge (0/1)

=cut

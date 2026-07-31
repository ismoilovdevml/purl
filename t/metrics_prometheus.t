#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# Prometheus exporter regressions.
#
# THE BUG: System::metrics interpolated $stats->{total_logs} and
# $stats->{db_size_bytes} with NO `// 0` fallback. When ClickHouse is down,
# stats() returns {} and the exporter emits
#
#     purl_logs_stored
#
# — a metric name with no value. Prometheus rejects the ENTIRE scrape as
# malformed, so at the exact moment the database dies you also lose the
# request rate, the error rate and every other metric on the endpoint.
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Metrics::Prometheus;
use Purl::Metrics::Counters;
use Purl::Store::Counter;

# Every non-comment, non-blank line must be `name value` or
# `name{labels} value` with a parseable numeric value.
sub _assert_parseable {
    my ($text, $label) = @_;
    my @bad;
    for my $line (split /\n/, $text) {
        next if $line =~ /^\s*$/;
        next if $line =~ /^#/;
        push @bad, $line
            unless $line =~ /^[a-zA-Z_:][a-zA-Z0-9_:]*(?:\{[^}]*\})?\s+-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/;
    }
    is_deeply \@bad, [], "$label: every sample line is valid exposition format";
    return;
}

# ---------------------------------------------------------------------------
# The regression itself
# ---------------------------------------------------------------------------
subtest 'exporter stays valid when ClickHouse is down' => sub {
    my $text = Purl::Metrics::Prometheus::render(
        version            => '1.2.0',
        uptime_seconds     => 100,
        clickhouse_healthy => 0,
        stats              => {},          # what stats() yields during an outage
        cache_size         => 0,
        counters           => {},
    );

    _assert_parseable($text, 'ClickHouse down');
    like $text, qr/^purl_logs_stored 0$/m, 'purl_logs_stored falls back to 0';
    like $text, qr/^purl_db_size_bytes 0$/m, 'purl_db_size_bytes falls back to 0';
    unlike $text, qr/^purl_logs_stored\s*$/m, 'never emits a bare metric name';
    like $text, qr/^purl_clickhouse_healthy 0$/m, 'reports the outage as a metric';
};

subtest 'exporter is valid with completely absent inputs' => sub {
    my $text = Purl::Metrics::Prometheus::render();
    _assert_parseable($text, 'no inputs at all');
    like $text, qr/^purl_clickhouse_healthy 0$/m, 'unhealthy by default';
};

subtest 'non-numeric storage values are coerced, not interpolated' => sub {
    my $text = Purl::Metrics::Prometheus::render(
        stats => { total_logs => 'N/A', db_size_bytes => undef },
        clickhouse_healthy => 1,
    );
    _assert_parseable($text, 'garbage stats');
    like $text, qr/^purl_logs_stored 0$/m, 'non-numeric string becomes 0';
};

subtest 'healthy instance reports real values' => sub {
    my $text = Purl::Metrics::Prometheus::render(
        version            => '1.2.0',
        uptime_seconds     => 3600,
        clickhouse_healthy => 1,
        stats              => { total_logs => 12345, db_size_bytes => 987654321 },
        cache_size         => 4,
        counters           => {},
    );
    _assert_parseable($text, 'healthy');
    like $text, qr/^purl_logs_stored 12345$/m, 'log count exported';
    like $text, qr/^purl_db_size_bytes 987654321$/m, 'db size exported';
    like $text, qr/^purl_clickhouse_healthy 1$/m, 'healthy = 1';
    like $text, qr/^purl_info\{version="1\.2\.0"\} 1$/m, 'version label';
};

# ---------------------------------------------------------------------------
# New metric families the chart alerts expect
# ---------------------------------------------------------------------------
subtest 'all required metric families are present' => sub {
    my $text = Purl::Metrics::Prometheus::render(counters => {});
    for my $metric (qw(
        purl_http_requests_total
        purl_errors_total
        purl_query_latency_seconds_sum
        purl_query_latency_seconds_count
        purl_clickhouse_healthy
        purl_ingest_bytes_total
    )) {
        like $text, qr/^\Q$metric\E[\s{]/m, "$metric exported";
    }
};

subtest 'metric families exist even with zero traffic' => sub {
    my $text = Purl::Metrics::Prometheus::render(counters => {});
    like $text, qr/^purl_http_requests_total\{[^}]*\} 0$/m,
        'request family present before the first request (rate() stays stable)';
    like $text, qr/^# TYPE purl_http_requests_total counter$/m, 'declared as a counter';
};

subtest 'labelled request counters render' => sub {
    my $text = Purl::Metrics::Prometheus::render(counters => {
        requests => {
            GET  => { '200' => 42, '404' => 3 },
            POST => { '201' => 7, '500' => 1 },
        },
        errors_total       => 4,
        latency_ms_sum     => 2500,
        latency_count      => 53,
        ingest_bytes_total => 1_048_576,
    });

    _assert_parseable($text, 'labelled counters');
    like $text, qr/^purl_http_requests_total\{method="GET",status="200"\} 42$/m, 'GET 200';
    like $text, qr/^purl_http_requests_total\{method="POST",status="500"\} 1$/m, 'POST 500';
    like $text, qr/^purl_errors_total 4$/m, 'error counter';
    like $text, qr/^purl_query_latency_seconds_sum 2\.500$/m, 'ms sum converted to seconds';
    like $text, qr/^purl_query_latency_seconds_count 53$/m, 'latency count';
    like $text, qr/^purl_ingest_bytes_total 1048576$/m, 'ingest bytes';
};

subtest 'label values are escaped' => sub {
    my $text = Purl::Metrics::Prometheus::render(version => 'v"1.0\\beta');
    _assert_parseable($text, 'escaped labels');
    like $text, qr/purl_info\{version="v\\"1\.0\\\\beta"\}/, 'quote and backslash escaped';
};

# ---------------------------------------------------------------------------
# Counters (prefork-shared)
# ---------------------------------------------------------------------------
sub _counters {
    return Purl::Metrics::Counters->new(
        store => Purl::Store::Counter->new(redis_url => ''),   # in-memory fallback
    );
}

subtest 'record_request accumulates by method and status' => sub {
    my $counters = _counters();
    $counters->record_request(method => 'GET',  status => 200, duration_ms => 10);
    $counters->record_request(method => 'GET',  status => 200, duration_ms => 20);
    $counters->record_request(method => 'POST', status => 500, duration_ms => 30);

    my $snapshot = $counters->snapshot;
    is $snapshot->{requests}{GET}{200}, 2, 'two GET 200s';
    is $snapshot->{requests}{POST}{500}, 1, 'one POST 500';
    is $snapshot->{errors_total}, 1, 'only the 500 counted as an error';
    is $snapshot->{latency_ms_sum}, 60, 'latencies summed in ms';
    is $snapshot->{latency_count}, 3, 'all three requests counted';
};

subtest 'unknown methods and statuses fold into an "other" bucket' => sub {
    my $counters = _counters();
    $counters->record_request(method => 'PROPFIND', status => 418, duration_ms => 1);

    my $snapshot = $counters->snapshot;
    is $snapshot->{requests}{other}{other}, 1,
        'label cardinality stays bounded so a scrape can enumerate the keys';
};

subtest 'record_ingest_bytes accumulates' => sub {
    my $counters = _counters();
    $counters->record_ingest_bytes(1000);
    $counters->record_ingest_bytes(24);
    is $counters->snapshot->{ingest_bytes_total}, 1024, 'bytes summed via INCRBY';

    ok !$counters->record_ingest_bytes(0), 'zero is a no-op';
    is $counters->snapshot->{ingest_bytes_total}, 1024, 'total unchanged';
};

subtest 'counters never throw on a broken store' => sub {
    {
        package ExplodingStore;
        sub new       { bless {}, $_[0] }
        sub incr      { die "redis is gone" }
        sub incr_by   { die "redis is gone" }
        sub get       { die "redis is gone" }
        sub is_shared { die "redis is gone" }
    }

    my $counters = Purl::Metrics::Counters->new(store => ExplodingStore->new);
    my $ok = eval { $counters->record_request(method => 'GET', status => 200, duration_ms => 5); 1 };
    ok $ok, 'a metrics failure never propagates into the request path';

    my $snapshot = eval { $counters->snapshot };
    ok $snapshot, 'snapshot still returns a structure';
    is $snapshot->{errors_total}, 0, 'unreadable counters read as 0, not undef';

    my $text = Purl::Metrics::Prometheus::render(counters => $snapshot);
    _assert_parseable($text, 'broken store');
};

# ---------------------------------------------------------------------------
# Store::Counter incr_by (the primitive the counters are built on)
# ---------------------------------------------------------------------------
subtest 'Store::Counter incr_by adds in one step' => sub {
    my $store = Purl::Store::Counter->new(redis_url => '');
    is $store->incr_by('k', 5, 60), 5, 'first add creates the key at 5';
    is $store->incr_by('k', 3, 60), 8, 'second add accumulates';
    is $store->get('k'), 8, 'readback matches';
};

subtest 'Store::Counter incr still increments by one' => sub {
    my $store = Purl::Store::Counter->new(redis_url => '');
    $store->incr('k', 60) for 1 .. 3;
    is $store->get('k'), 3, 'incr unchanged by the incr_by refactor';
};

done_testing();

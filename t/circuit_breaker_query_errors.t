#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ============================================
# The circuit breaker opens only when ClickHouse cannot be used (#108).
#
# On a production cluster three searches in a row failed with MEMORY_LIMIT_EXCEEDED;
# the breaker counted them like a dead server, opened, and every endpoint
# (alerts, patterns, health) failed for 30 s. A ClickHouse ANSWER about one
# query proves the server is up: it must neither count toward opening the
# breaker nor keep it open.
# ============================================

{
    package BreakerHost;
    use Moo;
    has '_metrics' => (is => 'rw', default => sub { {} });
    with 'Purl::Storage::ClickHouse::CircuitBreaker';
}

# Bodies as clickhouse-server 25.11 sends them (trimmed).
my %BODY = (
    oom     => 'Code: 241. DB::Exception: (total) memory limit exceeded: would use 2.42 GiB (attempt to allocate chunk of 4.18 MiB), current RSS: 2.73 GiB, maximum: 2.70 GiB. OvercommitTracker decision: Query was selected to stop by OvercommitTracker: (while reading column meta): (while reading from part /var/lib/clickhouse/store/4c9/4c9a89a8-1430-4899-866b-3510dd305696/20260923_1091_1208_20/ in table purl.logs): While executing MergeTreeSelect. (MEMORY_LIMIT_EXCEEDED) (version 25.11.9.34 (official build))',
    timeout => 'Code: 159. DB::Exception: Timeout exceeded: elapsed 30.001 seconds, maximum: 30. (TIMEOUT_EXCEEDED) (version 25.11.9.34 (official build))',
    syntax  => 'Code: 62. DB::Exception: Syntax error: failed at position 8: FROM. (SYNTAX_ERROR) (version 25.11.9.34 (official build))',
    auth    => 'Code: 516. DB::Exception: purl: Authentication failed: password is incorrect, or there is no user with such name. (AUTHENTICATION_FAILED) (version 25.11.9.34 (official build))',
    nodb    => 'Code: 81. DB::Exception: Database purl does not exist. (UNKNOWN_DATABASE) (version 25.11.9.34 (official build))',
);

sub failure { my ($status, $body) = @_; return "ClickHouse error: $status - $body" }

sub fresh {
    my $b = BreakerHost->new;
    local $SIG{__WARN__} = sub { };
    return $b;
}

sub hit {
    my ($b, $n, $text) = @_;
    local $SIG{__WARN__} = sub { };
    $b->_circuit_record(0, 0.01, $text) for 1 .. $n;
    return $b;
}

subtest 'query-level errors never open the breaker' => sub {
    for my $case (
        [ 'MEMORY_LIMIT_EXCEEDED', failure(500, $BODY{oom}) ],
        [ 'TIMEOUT_EXCEEDED',      failure(500, $BODY{timeout}) ],
        [ 'SYNTAX_ERROR',          failure(400, $BODY{syntax}) ],
    ) {
        my ($name, $text) = @$case;
        my $b = hit(fresh(), 10, $text);
        is $b->_circuit_state, 'closed', "$name x10: still closed";
        is $b->_consecutive_failures, 0, "$name: not counted as an outage";
        is $b->_metrics->{errors_total}, 10, "$name: still counted as an error";
        is $b->_metrics->{query_errors_total}, 10, "$name: counted as a query error";
    }
};

subtest 'outages still open it after the threshold' => sub {
    for my $case (
        [ 'connection refused (599)', failure(599, 'Could not connect to purl-clickhouse:8123: Connection refused') ],
        [ 'read timeout (599)',       failure(599, 'Timed out while waiting for socket to become ready for reading') ],
        [ 'AUTHENTICATION_FAILED',    failure(516, $BODY{auth}) ],
        [ 'UNKNOWN_DATABASE',         failure(404, $BODY{nodb}) ],
        [ 'transport die',            "Cannot write /tmp/export.csv: No space left on device\n" ],
        [ 'no detail',                undef ],
    ) {
        my ($name, $text) = @$case;
        my $b = hit(fresh(), 2, $text);
        is $b->_circuit_state, 'closed', "$name x2: below threshold";
        hit($b, 1, $text);
        is $b->_circuit_state, 'open', "$name x3: open";
    }
};

subtest 'a query-level error in between resets the outage count' => sub {
    my $b = hit(fresh(), 2, failure(599, 'Connection refused'));
    hit($b, 1, failure(500, $BODY{oom}));
    hit($b, 2, failure(599, 'Connection refused'));
    is $b->_circuit_state, 'closed', 'refused, refused, OOM, refused, refused: closed';
};

subtest 'a query-level error while half-open closes the breaker' => sub {
    my $b = hit(fresh(), 3, failure(599, 'Connection refused'));
    is $b->_circuit_state, 'open', 'opened by the outage';
    $b->_circuit_opened_at(0);    # cooldown elapsed
    $b->_circuit_guard;
    is $b->_circuit_state, 'half_open', 'probing';
    hit($b, 1, failure(500, $BODY{oom}));
    is $b->_circuit_state, 'closed', 'the server answered: closed again';
};

done_testing;

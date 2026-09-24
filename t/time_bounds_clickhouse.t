#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use POSIX ();

# ============================================
# #121 / #109 against REAL ClickHouse: every storage path that takes a time
# bound gets it in each accepted format (Z, offset, fraction, epoch, epoch ms)
# and returns the same rows; an ingest timestamp with an offset lands at the
# right UTC instant instead of failing the whole insert; a row stored without
# a timestamp on a non-UTC host is found by a "last 5 minutes" search.
#
# Runs under TZ=Asia/Tashkent. Own throwaway database (purl_t121_<pid>).
# ============================================

$ENV{TZ} = 'Asia/Tashkent';
POSIX::tzset();

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
);
my $db = "purl_t121_$$";

my $http = HTTP::Tiny->new(timeout => 30);
my $base = sprintf('http://%s:%d/?user=%s&password=%s',
    $conn{host}, $conn{port}, $conn{username}, $conn{password});
sub ch {
    my ($sql) = @_;
    my $res = $http->post($base, { content => $sql });
    die "ClickHouse: $res->{status} $res->{content}\n" unless $res->{success};
    my $out = $res->{content};
    chomp $out;
    return $out;
}

unless (eval { ch('SELECT 1') eq '1' }) {
    plan skip_all =>
        "No reachable ClickHouse at $conn{host}:$conn{port}. Time-bound normalisation (#121) "
      . "against ClickHouse is therefore UNVERIFIED in this run.";
}
END { eval { ch("DROP DATABASE IF EXISTS $db SYNC") } if $db; }

require Purl::Storage::ClickHouse;
my $storage = Purl::Storage::ClickHouse->new(%conn, database => $db, durable => 1, use_query_cache => 0);

# Three rows 10 minutes apart around 2026-09-23 18:40..19:00 UTC; the middle
# one arrives with a +05:00 offset (Tashkent wall clock).
$storage->insert({ service => 't121', message => 'r1', timestamp => '2026-09-23T18:40:00Z' });
$storage->insert({ service => 't121', message => 'r2', timestamp => '2026-09-23T23:50:00.500+05:00' });
$storage->insert({ service => 't121', message => 'r3', timestamp => '2026-09-23T19:00:00Z' });
is eval { $storage->flush }, 3, 'batch with an offset timestamp is accepted (it used to fail the insert)'
    or diag $@;
is ch("SELECT toString(timestamp) FROM $db.logs WHERE message = 'r2'"), '2026-09-23 18:50:00.500',
    'offset timestamp stored as the right UTC instant';

# A window 18:45..18:55 UTC must contain exactly r2, however it is spelled.
my %windows = (
    'Z'           => ['2026-09-23T18:45:00Z',          '2026-09-23T18:55:00Z'],
    'fraction Z'  => ['2026-09-23T18:45:00.000Z',      '2026-09-23T18:55:00.999Z'],
    '+05:00'      => ['2026-09-23T23:45:00+05:00',     '2026-09-23T23:55:00+05:00'],
    '-03:00'      => ['2026-09-23T15:45:00-03:00',     '2026-09-23T15:55:00-03:00'],
    'epoch s'     => ['1790189100',                    '1790189700'],
    'epoch ms'    => ['1790189100000',                 '1790189700000'],
    'CH format'   => ['2026-09-23 18:45:00',           '2026-09-23 18:55:00'],
);
for my $name (sort keys %windows) {
    my ($from, $to) = @{ $windows{$name} };
    my %p = (from => $from, to => $to, service => 't121');

    my $rows = eval { $storage->search(%p, limit => 10) };
    is $@, '', "search ($name) does not error";
    is_deeply [ map { $_->{message} } @{ $rows // [] } ], ['r2'], "search ($name) returns r2 only";

    is eval { $storage->count(%p) }, 1, "count ($name)";

    my $hist = eval { $storage->histogram(%p, interval => '1 minute') };
    is $@, '', "histogram ($name) does not error";
    my $total = 0;
    $total += $_->{count} // 0 for @{ $hist // [] };
    is $total, 1, "histogram ($name) counts r2";

    my $facets = eval { $storage->field_stats('service', %p) };
    is $@, '', "facets ($name) do not error";
}

# An unreadable bound is ignored — and must not make the histogram fill from
# 1970 (it built ~497k empty buckets at 1 minute).
for my $bad ([from => 'bogus', to => '2026-09-23T19:00:00Z'], [from => 'bogus', to => 'also-bogus']) {
    my $hist = eval { $storage->histogram(@$bad, service => 't121', interval => '1 minute') };
    is $@, '', "histogram(@$bad) does not error";
    cmp_ok scalar @{ $hist // [] }, '<=', 100, "histogram(@$bad) stays bounded (" . scalar(@{ $hist // [] }) . ' buckets)';
}

# #109: a row stored WITHOUT a timestamp is stamped now, in UTC.
$storage->insert({ service => 't121-now', message => 'now-row' });
$storage->flush;
my $rows = $storage->search(service => 't121-now', range => '5m', limit => 10);
is scalar @$rows, 1, 'row without timestamp is inside "last 5 minutes" on a UTC+5 host';

done_testing;

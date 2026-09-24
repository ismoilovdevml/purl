#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use POSIX ();
use Purl::Util::Time qw(to_clickhouse_ts now_clickhouse);

# ============================================
# #121 — every time bound (search, histogram, facets, patterns, traces,
# dashboards, ingest timestamps) goes through ONE normaliser to UTC
# 'YYYY-MM-DD HH:MM:SS.fff'. It used to strip a trailing Z and nothing else:
# an offset ('+05:00') produced '...18:47:28+05:00.000', which the storage
# layer silently dropped as a filter — and which, as an ingest timestamp,
# made ClickHouse reject the whole insert batch.
#
# #109 — now_clickhouse() formatted LOCAL time, so a row stored without a
# timestamp on a non-UTC host landed hours outside the searched range.
#
# Run under TZ=Asia/Tashkent (UTC+5, the production host's zone) so any
# local-time leak shows up as a 5 hour error.
# ============================================

$ENV{TZ} = 'Asia/Tashkent';
POSIX::tzset();
my $local_off = do { my $t = 1790189248; my @l = localtime($t); my @g = gmtime($t); ($l[2] - $g[2]) % 24 };
is $local_off, 5, 'test really runs 5h east of UTC';

my %cases = (
    'Z suffix'                  => ['2026-09-23T18:47:28Z',          '2026-09-23 18:47:28.000'],
    'lower-case z'              => ['2026-09-23t18:47:28z',          '2026-09-23 18:47:28.000'],
    'fractional + Z'            => ['2026-09-23T18:47:28.123Z',      '2026-09-23 18:47:28.123'],
    'microseconds truncated'    => ['2026-09-23T18:47:28.123456Z',   '2026-09-23 18:47:28.123'],
    'one fractional digit'      => ['2026-09-23T18:47:28.5Z',        '2026-09-23 18:47:28.500'],
    'positive offset'           => ['2026-09-23T23:47:28+05:00',     '2026-09-23 18:47:28.000'],
    'negative offset'           => ['2026-09-23T13:47:28-05:00',     '2026-09-23 18:47:28.000'],
    'offset without colon'      => ['2026-09-23T23:47:28+0500',      '2026-09-23 18:47:28.000'],
    'offset crossing midnight'  => ['2026-09-24T02:00:00+05:00',     '2026-09-23 21:00:00.000'],
    'fraction + offset'         => ['2026-09-23T23:47:28.250+05:00', '2026-09-23 18:47:28.250'],
    'no zone = UTC'             => ['2026-09-23T18:47:28',           '2026-09-23 18:47:28.000'],
    'ClickHouse format as is'   => ['2026-09-23 18:47:28.123',       '2026-09-23 18:47:28.123'],
    'ClickHouse, no fraction'   => ['2026-09-23 18:47:28',           '2026-09-23 18:47:28.000'],
    'minutes only'              => ['2026-09-23T18:47Z',             '2026-09-23 18:47:00.000'],
    'date only'                 => ['2026-09-23',                    '2026-09-23 00:00:00.000'],
    'epoch seconds'             => ['1790189248',                    '2026-09-23 18:47:28.000'],
    'epoch seconds, fraction'   => ['1790189248.5',                  '2026-09-23 18:47:28.500'],
    'epoch milliseconds'        => ['1790189248123',                 '2026-09-23 18:47:28.123'],
);
for my $name (sort keys %cases) {
    my ($in, $want) = @{ $cases{$name} };
    is to_clickhouse_ts($in), $want, "$name: $in";
}

for my $bad ('garbage', '2026-13-01T00:00:00Z', '2026-02-30', '2026-09-23T25:00:00Z',
             "2026-09-23T18:47:28Z'; DROP TABLE logs", 'now-15m', '12345') {
    is to_clickhouse_ts($bad), '', "rejected: $bad";
}
is to_clickhouse_ts(undef), '', 'undef => empty';
is to_clickhouse_ts(''),    '', 'empty => empty';

# #109
{
    my $before = time();
    my $ch = now_clickhouse();
    like $ch, qr/^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}$/, 'now_clickhouse format';
    my @g = gmtime($before);
    my $utc_prefix = sprintf('%04d-%02d-%02d %02d', $g[5] + 1900, $g[4] + 1, $g[3], $g[2]);
    is substr($ch, 0, 13), $utc_prefix, 'now_clickhouse is UTC, not Asia/Tashkent local time'
        unless $g[1] == 59 && $g[0] >= 58;   # hour rollover between the two reads
}

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use_ok('Purl::Util::Time', qw(
    epoch_to_iso
    parse_time_range
    format_duration
    to_clickhouse_ts
    now_iso
    now_clickhouse
));

# epoch_to_iso
is(epoch_to_iso(0),          '1970-01-01T00:00:00Z', 'epoch 0 → Unix epoch');
is(epoch_to_iso(1703412600), '2023-12-24T10:10:00Z', 'known epoch → ISO8601');
is(epoch_to_iso(undef),      '',                      'undef → empty string');

# parse_time_range
{
    my ($from, $to) = parse_time_range('15m');
    ok(defined $from && defined $to, '15m returns two timestamps');
    like($from, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, '15m from is ISO8601');

    my ($f2, $t2) = parse_time_range('2h');
    ok(defined $f2, '2h returns from');

    my ($f3, $t3) = parse_time_range('7d');
    ok(defined $f3, '7d returns from');

    my ($fx, $tx) = parse_time_range('invalid');
    ok(!defined $fx && !defined $tx, 'invalid range → undef, undef');

    my ($fn, $tn) = parse_time_range(undef);
    ok(!defined $fn, 'undef range → undef');
}

# format_duration
is(format_duration(0),      '0s',      'zero seconds');
is(format_duration(45),     '45s',     '45 seconds');
is(format_duration(90),     '1m 30s',  '90 seconds → 1m 30s');
is(format_duration(3600),   '1h',      '3600 seconds → 1h');
is(format_duration(3661),   '1h 1m',   '3661 seconds → 1h 1m');
is(format_duration(90061),  '1d 1h 1m', '90061 seconds → 1d 1h 1m');
is(format_duration(86400),  '1d',      '86400 seconds → 1d');
is(format_duration(undef),  '0s',      'undef → 0s');

# to_clickhouse_ts
is(to_clickhouse_ts('2024-12-24T10:30:00Z'),
   '2024-12-24 10:30:00.000',
   'ISO8601 → ClickHouse format');
is(to_clickhouse_ts('2024-12-24T10:30:00.123Z'),
   '2024-12-24 10:30:00.123',
   'ISO8601 with ms → ClickHouse format');
is(to_clickhouse_ts(undef), '', 'undef → empty string');
is(to_clickhouse_ts(''),    '', 'empty string → empty string');

# now_iso / now_clickhouse — just check format
{
    my $iso = now_iso();
    like($iso, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'now_iso returns ISO8601');

    my $ch = now_clickhouse();
    like($ch, qr/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$/, 'now_clickhouse returns ClickHouse format');
}

done_testing();

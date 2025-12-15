#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'lib';
use Purl::Utils qw(format_duration parse_time_range epoch_to_iso url_encode);

# Test format_duration
subtest 'format_duration' => sub {
    is(format_duration(0), '0s', 'zero seconds');
    is(format_duration(30), '30s', '30 seconds');
    is(format_duration(60), '1m', 'one minute');
    is(format_duration(90), '1m 30s', '90 seconds');
    is(format_duration(3600), '1h', 'one hour');
    # Note: format_duration only shows max 2 units
    is(format_duration(3661), '1h 1m', 'one hour one minute (no seconds - max 2 units)');
    is(format_duration(86400), '1d', 'one day');
    # Note: format_duration limits seconds to 2 units, but allows d/h/m
    is(format_duration(90061), '1d 1h 1m', 'complex duration');
};

# Test parse_time_range
subtest 'parse_time_range' => sub {
    my ($from, $to) = parse_time_range('15m');
    ok($from, '15m: from is set');
    ok($to, '15m: to is set');
    like($from, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, '15m: from is ISO format');
    like($to, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, '15m: to is ISO format');

    ($from, $to) = parse_time_range('1h');
    ok($from && $to, '1h: both values set');

    ($from, $to) = parse_time_range('24h');
    ok($from && $to, '24h: both values set');

    ($from, $to) = parse_time_range('7d');
    ok($from && $to, '7d: both values set');

    # Invalid range
    ($from, $to) = parse_time_range('invalid');
    ok(!defined $from && !defined $to, 'invalid range returns undef');
};

# Test epoch_to_iso
subtest 'epoch_to_iso' => sub {
    my $epoch = 1702656000;  # Known epoch
    my $iso = epoch_to_iso($epoch);
    like($iso, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'ISO format is correct');
    is($iso, '2023-12-15T16:00:00Z', 'Correct ISO string for known epoch');
};

# Test url_encode
subtest 'url_encode' => sub {
    is(url_encode('hello'), 'hello', 'simple string unchanged');
    is(url_encode('hello world'), 'hello%20world', 'space encoded');
    is(url_encode('a=b&c=d'), 'a%3Db%26c%3Dd', 'special chars encoded');
    is(url_encode('test@example.com'), 'test%40example.com', 'email encoded');
};

done_testing();

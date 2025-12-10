#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use_ok('Purl::Parser::Engine');

my $parser = Purl::Parser::Engine->new();

# Test nginx combined parsing
{
    my $line = '192.168.1.1 - john [10/Dec/2024:10:23:45 +0000] "GET /api/users HTTP/1.1" 200 1234 "https://example.com" "Mozilla/5.0"';
    my $result = $parser->parse($line, 'nginx_combined');

    ok($result, 'Parsed nginx combined');
    is($result->{remote_ip}, '192.168.1.1', 'Correct remote IP');
    is($result->{method}, 'GET', 'Correct method');
    is($result->{path}, '/api/users', 'Correct path');
    is($result->{status}, 200, 'Correct status');
    is($result->{bytes}, 1234, 'Correct bytes');
}

# Test JSON parsing
{
    my $line = '{"timestamp":"2024-12-10T10:23:45Z","level":"ERROR","message":"Connection refused","service":"api"}';
    my $result = $parser->parse($line, 'json');

    ok($result, 'Parsed JSON');
    is($result->{level}, 'ERROR', 'Correct level');
    is($result->{message}, 'Connection refused', 'Correct message');
    is($result->{service}, 'api', 'Correct service');
}

# Test nginx error parsing
{
    my $line = '2024/12/10 10:23:45 [error] 1234#5678: *9999 upstream timed out';
    my $result = $parser->parse($line, 'nginx_error');

    ok($result, 'Parsed nginx error');
    is($result->{level}, 'ERROR', 'Correct level');
    is($result->{pid}, 1234, 'Correct pid');
    is($result->{tid}, 5678, 'Correct tid');
    like($result->{message}, qr/upstream timed out/, 'Correct message');
}

# Test syslog parsing
{
    my $line = 'Dec 10 10:23:45 server01 nginx[1234]: upstream connection refused';
    my $result = $parser->parse($line, 'syslog');

    ok($result, 'Parsed syslog');
    is($result->{host}, 'server01', 'Correct host');
    is($result->{program}, 'nginx', 'Correct program');
    is($result->{pid}, 1234, 'Correct pid');
}

# Test auto-detection
{
    my $json_line = '{"level":"INFO","message":"test"}';
    my $result = $parser->parse($json_line);

    ok($result, 'Auto-detected and parsed');
    is($result->{_format}, 'json', 'Auto-detected JSON format');
}

# Test fallback to raw
{
    my $line = 'some random text that does not match any format';
    my $result = $parser->parse($line);

    ok($result, 'Returns result for unknown format');
    is($result->{message}, $line, 'Message is the raw line');
    is($result->{_format}, 'raw', 'Format is raw');
}

done_testing();

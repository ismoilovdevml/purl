#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use_ok('Purl::Parser::FormatDetector');

my $detector = Purl::Parser::FormatDetector->new();

# Test nginx combined format
{
    my $line = '192.168.1.1 - - [10/Dec/2024:10:23:45 +0000] "GET /api/users HTTP/1.1" 200 1234 "-" "Mozilla/5.0"';
    my $format = $detector->detect_line($line);
    is($format, 'nginx_combined', 'Detects nginx combined format');
}

# Test nginx error format
{
    my $line = '2024/12/10 10:23:45 [error] 1234#5678: *9999 connection refused';
    my $format = $detector->detect_line($line);
    is($format, 'nginx_error', 'Detects nginx error format');
}

# Test JSON format
{
    my $line = '{"timestamp":"2024-12-10T10:23:45Z","level":"ERROR","message":"test"}';
    my $format = $detector->detect_line($line);
    is($format, 'json', 'Detects JSON format');
}

# Test syslog format
{
    my $line = 'Dec 10 10:23:45 server01 nginx[1234]: test message';
    my $format = $detector->detect_line($line);
    is($format, 'syslog', 'Detects syslog format');
}

# Test docker JSON format
{
    my $line = '{"log":"hello world\n","stream":"stdout","time":"2024-12-10T10:23:45.123Z"}';
    my $format = $detector->detect_line($line);
    is($format, 'docker_json', 'Detects docker JSON format');
}

# Test CLF format
{
    my $line = '192.168.1.1 - john [10/Dec/2024:10:23:45 +0000] "GET /index.html HTTP/1.1" 200 1024';
    my $format = $detector->detect_line($line);
    is($format, 'clf', 'Detects CLF format');
}

# Test supported formats
{
    my @formats = $detector->supported_formats();
    ok(scalar(@formats) > 5, 'Has multiple supported formats');
    ok(grep { $_ eq 'json' } @formats, 'Supports JSON');
    ok(grep { $_ eq 'nginx_combined' } @formats, 'Supports nginx_combined');
}

done_testing();

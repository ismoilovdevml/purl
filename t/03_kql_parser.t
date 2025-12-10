#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use_ok('Purl::Query::KQL');

my $kql = Purl::Query::KQL->new();

# Test simple field:value
{
    my $result = $kql->parse('level:ERROR');
    like($result->{sql}, qr/level\s*=\s*\?/, 'Simple field match generates SQL');
    is($result->{bind}[0], 'ERROR', 'Correct bind value');
}

# Test wildcard
{
    my $result = $kql->parse('service:api*');
    like($result->{sql}, qr/service\s+LIKE\s+\?/, 'Wildcard generates LIKE');
    is($result->{bind}[0], 'api%', 'Wildcard converted to %');
}

# Test AND
{
    my $result = $kql->parse('level:ERROR AND service:nginx');
    like($result->{sql}, qr/AND/, 'AND generates SQL AND');
    is(scalar(@{$result->{bind}}), 2, 'Two bind values');
}

# Test OR
{
    my $result = $kql->parse('level:ERROR OR level:WARN');
    like($result->{sql}, qr/OR/, 'OR generates SQL OR');
}

# Test NOT
{
    my $result = $kql->parse('NOT level:DEBUG');
    like($result->{sql}, qr/NOT/, 'NOT generates SQL NOT');
}

# Test parentheses
{
    my $result = $kql->parse('(level:ERROR OR level:WARN) AND service:api');
    like($result->{sql}, qr/\(.*OR.*\).*AND/, 'Parentheses preserved');
}

# Test quoted phrase
{
    my $result = $kql->parse('message:"connection refused"');
    like($result->{sql}, qr/message\s+LIKE\s+\?/, 'Quoted phrase generates LIKE');
    like($result->{bind}[0], qr/connection refused/, 'Contains the phrase');
}

# Test implicit AND
{
    my $result = $kql->parse('level:ERROR service:nginx');
    like($result->{sql}, qr/AND/, 'Implicit AND');
}

# Test time range
{
    my $result = $kql->parse('@timestamp>now-1h');
    like($result->{sql}, qr/timestamp\s*>=?\s*\?/, 'Time range generates comparison');
    ok($result->{bind}[0], 'Has timestamp bind value');
}

# Test empty query
{
    my $result = $kql->parse('');
    is($result->{sql}, '1=1', 'Empty query returns 1=1');
}

# Test explain
{
    my $result = $kql->explain('level:ERROR');
    ok($result->{original}, 'Has original');
    ok($result->{sql}, 'Has SQL');
    ok($result->{bind}, 'Has bind values');
}

done_testing();

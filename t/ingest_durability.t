#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use Time::HiRes qw(time);
use Purl::Storage::ClickHouse;

# ============================================
# REAL durability test — requires a live ClickHouse.
#
# In durable mode (wait_for_async_insert=1) a successful flush() MUST mean the
# row is queryable straight back. This is NOT mocked: we insert a unique marker,
# flush, then SELECT it directly from ClickHouse and assert it is present.
#
# Connection comes from PURL_CLICKHOUSE_* env (same as the app). If no
# ClickHouse is reachable the whole test is skipped with a clear message — we
# never fake a pass.
# ============================================

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
    database => $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl',
);

# Probe reachability without side effects.
my $reachable = do {
    my $http = HTTP::Tiny->new(timeout => 5);
    my $url  = sprintf('http://%s:%d/?user=%s&password=%s',
        $conn{host}, $conn{port}, $conn{username}, $conn{password});
    my $res = $http->post($url, { content => 'SELECT 1' });
    $res->{success} ? 1 : 0;
};

unless ($reachable) {
    plan skip_all =>
        "No reachable ClickHouse at $conn{host}:$conn{port} (user=$conn{username}). "
      . "Durability across the wire is therefore UNVERIFIED in this run. "
      . "Set PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD/DATABASE to a live instance to run it.";
}

my $storage = eval {
    Purl::Storage::ClickHouse->new(%conn, durable => 1);
};
unless ($storage) {
    plan skip_all => "Could not initialise ClickHouse storage/schema: $@";
}

plan tests => 5;

is $storage->durable, 1, 'storage is in durable mode';

my $marker = sprintf('purl-durability-%d-%d-%d', time() * 1000, $$, int(rand(1e6)));

$storage->insert({
    level   => 'ERROR',
    service => 'durability-test',
    host    => 'test-host',
    message => $marker,
});

my $flushed = $storage->flush;
is $flushed, 1, 'flush() reported 1 row written';

# With wait_for_async_insert=1, flush() returned only after the row is durable.
# Read it straight back from ClickHouse — no cache, direct SELECT.
my $rows = $storage->search(query => $marker, limit => 10);
is scalar(@$rows), 1, 'exactly one row found immediately after durable flush';
is $rows->[0]{message}, $marker, 'the row we flushed is the row ClickHouse returns';

# Independent verification via a raw HTTP count, bypassing the storage layer
# entirely, so the assertion cannot be an artefact of storage-side caching.
my $count = do {
    my $http = HTTP::Tiny->new(timeout => 5);
    my $q = "SELECT count() FROM $conn{database}.logs WHERE message = {m:String}";
    my $url = sprintf('http://%s:%d/?user=%s&password=%s&param_m=%s',
        $conn{host}, $conn{port}, $conn{username}, $conn{password},
        _uri_escape($marker));
    my $res = $http->post($url, { content => $q });
    $res->{success} ? ($res->{content} =~ /(\d+)/ ? $1 : -1) : -1;
};
is $count, 1, 'raw HTTP SELECT count() confirms the durable row is in ClickHouse';

sub _uri_escape {
    my ($s) = @_;
    $s =~ s/([^A-Za-z0-9_.\-])/sprintf('%%%02X', ord($1))/ge;
    return $s;
}

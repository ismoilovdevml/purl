#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Cache is a Moo::Role; create consumer class with required attributes
{
    package TestCacheConsumer;
    use Moo;
    with 'Purl::Storage::ClickHouse::Cache';

    has 'use_query_cache' => (is => 'ro', default => 1);
    has '_metrics' => (is => 'rw', default => sub { { queries_cached => 0 } });
}

# ============================================
# _get_cache_key — deterministic key generation
# ============================================
subtest '_get_cache_key basics' => sub {
    my $c = TestCacheConsumer->new;
    my $key1 = $c->_get_cache_key('SELECT 1', {});
    ok defined $key1, 'key generated';
    like $key1, qr/^[a-f0-9]{32}$/, 'key is MD5 hex';

    my $key2 = $c->_get_cache_key('SELECT 1', {});
    is $key1, $key2, 'same input = same key (deterministic)';

    my $key3 = $c->_get_cache_key('SELECT 2', {});
    isnt $key1, $key3, 'different SQL = different key';
};

subtest '_get_cache_key with params' => sub {
    my $c = TestCacheConsumer->new;
    my $k1 = $c->_get_cache_key('SELECT *', { a => '1', b => '2' });
    my $k2 = $c->_get_cache_key('SELECT *', { b => '2', a => '1' });
    is $k1, $k2, 'param order does not matter (sorted)';

    my $k3 = $c->_get_cache_key('SELECT *', { a => '1', b => '3' });
    isnt $k1, $k3, 'different param values = different key';
};

subtest '_get_cache_key undef params' => sub {
    my $c = TestCacheConsumer->new;
    my $k1 = $c->_get_cache_key('SELECT 1', undef);
    my $k2 = $c->_get_cache_key('SELECT 1');
    is $k1, $k2, 'undef and missing params produce same key';
};

# ============================================
# _set_cached / _get_cached — store and retrieve
# ============================================
subtest 'cache set and get' => sub {
    my $c = TestCacheConsumer->new(cache_ttl => 60);
    $c->_set_cached('key1', [1, 2, 3]);
    my $val = $c->_get_cached('key1');
    is_deeply $val, [1, 2, 3], 'retrieve stored value';
};

subtest 'cache miss for unknown key' => sub {
    my $c = TestCacheConsumer->new;
    is $c->_get_cached('nonexistent'), undef, 'unknown key returns undef';
};

subtest 'cache TTL expiry' => sub {
    my $c = TestCacheConsumer->new(cache_ttl => 0);  # 0-second TTL = immediate expiry
    $c->_set_cached('expire_test', 'value');
    sleep 1;
    is $c->_get_cached('expire_test'), undef, 'expired entry returns undef';
};

subtest 'cache increments queries_cached metric' => sub {
    my $c = TestCacheConsumer->new(cache_ttl => 60);
    $c->_set_cached('metric_test', 'data');
    my $before = $c->_metrics->{queries_cached};
    $c->_get_cached('metric_test');
    is $c->_metrics->{queries_cached}, $before + 1, 'cache hit increments metric';
};

subtest 'cache disabled returns undef' => sub {
    my $c = TestCacheConsumer->new(use_query_cache => 0);
    $c->_set_cached('disabled_key', 'value');
    is $c->_get_cached('disabled_key'), undef, 'cache disabled returns undef';
};

# ============================================
# LRU eviction
# ============================================
subtest 'LRU eviction at capacity' => sub {
    my $c = TestCacheConsumer->new(cache_max_size => 5, cache_ttl => 60);

    # Fill cache
    for my $i (1..5) {
        $c->_set_cached("key$i", "val$i");
        select(undef, undef, undef, 0.01);  # tiny delay for timestamp ordering
    }
    is scalar keys %{$c->_query_cache}, 5, 'cache at capacity';

    # Add one more — triggers eviction of 20% (1 entry)
    $c->_set_cached('key6', 'val6');
    ok scalar keys %{$c->_query_cache} <= 5, 'eviction keeps size under max';
    ok defined $c->_get_cached('key6'), 'newest entry survives';
};

# ============================================
# clear_cache / invalidate_logs_cache
# ============================================
subtest 'clear_cache empties all' => sub {
    my $c = TestCacheConsumer->new(cache_ttl => 60);
    $c->_set_cached('a', 1);
    $c->_set_cached('b', 2);
    $c->clear_cache;
    is scalar keys %{$c->_query_cache}, 0, 'cache empty after clear';
    is scalar keys %{$c->_cache_timestamps}, 0, 'timestamps empty after clear';
};

subtest 'invalidate_logs_cache empties all' => sub {
    my $c = TestCacheConsumer->new(cache_ttl => 60);
    $c->_set_cached('x', 'y');
    $c->invalidate_logs_cache;
    is scalar keys %{$c->_query_cache}, 0, 'cache empty after invalidate';
};

# ============================================
# cache_stats
# ============================================
subtest 'cache_stats' => sub {
    my $c = TestCacheConsumer->new(cache_max_size => 500, cache_ttl => 30);
    $c->_set_cached('s1', 'v1');
    $c->_set_cached('s2', 'v2');

    my $stats = $c->cache_stats;
    is $stats->{entries}, 2, 'correct entry count';
    is $stats->{max_size}, 500, 'max_size from attribute';
    is $stats->{ttl_seconds}, 30, 'ttl from attribute';
};

done_testing;

package Purl::Storage::ClickHouse::Cache;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);
use Digest::MD5 qw(md5_hex);

# Cache attributes
has '_query_cache' => (
    is      => 'rw',
    default => sub { {} },
);

has '_cache_timestamps' => (
    is      => 'rw',
    default => sub { {} },
);

has 'cache_ttl' => (
    is      => 'ro',
    default => 5,  # seconds
);

has 'cache_max_size' => (
    is      => 'ro',
    default => 1000,  # Increased from 100 for better hit rate
);

# Eviction percentage (20% instead of 50% to reduce thrashing)
has '_eviction_rate' => (
    is      => 'ro',
    default => 0.2,
);

# ============================================
# Cache Management
# ============================================

# Generate cache key from SQL using MD5 for better distribution
sub _get_cache_key {
    my ($self, $sql) = @_;
    return md5_hex($sql);
}

# Get cached value
sub _get_cached {
    my ($self, $key) = @_;
    return unless $self->use_query_cache;

    my $cached = $self->_query_cache->{$key};
    my $ts = $self->_cache_timestamps->{$key};

    return unless $cached && $ts;
    return if (time() - $ts) > $self->cache_ttl;

    $self->_metrics->{queries_cached}++;
    return $cached;
}

# Set cached value with gradual LRU eviction (20% instead of 50%)
sub _set_cached {
    my ($self, $key, $value) = @_;
    return unless $self->use_query_cache;

    my $cache = $self->_query_cache;
    my $timestamps = $self->_cache_timestamps;

    # LRU eviction - evict 20% of oldest entries when at capacity
    if (keys %$cache >= $self->cache_max_size) {
        my @keys = sort { $timestamps->{$a} <=> $timestamps->{$b} } keys %$cache;
        my $to_delete = int(@keys * $self->_eviction_rate) || 1;
        for my $k (@keys[0..$to_delete-1]) {
            delete $cache->{$k};
            delete $timestamps->{$k};
        }
    }

    $cache->{$key} = $value;
    $timestamps->{$key} = time();
}

# Clear all cache
sub clear_cache {
    my ($self) = @_;
    $self->_query_cache({});
    $self->_cache_timestamps({});
}

# Get cache statistics
sub cache_stats {
    my ($self) = @_;
    return {
        entries     => scalar keys %{$self->_query_cache},
        max_size    => $self->cache_max_size,
        ttl_seconds => $self->cache_ttl,
    };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Cache - Query caching role with LRU eviction

=head1 DESCRIPTION

This role provides in-memory caching for ClickHouse queries with
TTL-based expiration and LRU eviction.

=cut

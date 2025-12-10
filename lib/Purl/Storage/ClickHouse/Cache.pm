package Purl::Storage::ClickHouse::Cache;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);

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
    default => 100,
);

# ============================================
# Cache Management
# ============================================

# Generate cache key from SQL
sub _get_cache_key {
    my ($self, $sql) = @_;
    # Simple hash for cache key
    my $key = 0;
    $key = ($key * 31 + ord($_)) % 2147483647 for split //, $sql;
    return $key;
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

# Set cached value with LRU eviction
sub _set_cached {
    my ($self, $key, $value) = @_;
    return unless $self->use_query_cache;

    # LRU eviction
    my $cache = $self->_query_cache;
    if (keys %$cache >= $self->cache_max_size) {
        my @keys = sort {
            $self->_cache_timestamps->{$a} <=> $self->_cache_timestamps->{$b}
        } keys %$cache;
        my $to_delete = int(@keys / 2);
        for my $k (@keys[0..$to_delete-1]) {
            delete $cache->{$k};
            delete $self->_cache_timestamps->{$k};
        }
    }

    $cache->{$key} = $value;
    $self->_cache_timestamps->{$key} = time();
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

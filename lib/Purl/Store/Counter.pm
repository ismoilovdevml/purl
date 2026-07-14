package Purl::Store::Counter;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Time::HiRes qw(time);

# ============================================================================
# Purl::Store::Counter
#
# A tiny shared counter abstraction for security state that MUST be consistent
# across prefork workers (rate limiting, per-username login lockout).
#
# When a Redis URL is configured AND reachable, counters live in Redis so every
# worker (and every replica) shares one atomic count. When Redis is not
# configured or goes down, it degrades to a per-instance in-memory hashref that
# is BEHAVIOUR-IDENTICAL to the pre-shared-store implementation.
#
# This mirrors the structure of Purl::Broadcast::Redis (soft `require Mojo::Redis`,
# `_redis_available` flag, local fallback) — same pattern, do not invent a new one.
# ============================================================================

# Redis connection URL (e.g. redis://redis:6379). Empty string => pure local.
has 'redis_url' => (
    is      => 'ro',
    default => sub { '' },
);

# Mojo::Redis instance (lazy; created + ping-tested on first use).
has '_redis' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_redis',
);

# Whether the Redis backend is currently usable. Flipped to 0 on any failure so
# subsequent calls fall through to the in-memory store (fail-open degradation).
has '_redis_available' => (
    is      => 'rw',
    default => sub { 0 },
);

# In-memory fallback: key => { count => N, expires_at => epoch_seconds }.
has '_local' => (
    is      => 'ro',
    default => sub { {} },
);

# Opportunistic local-store GC bookkeeping (amortised O(1), mirrors the old
# per-request cleanup in Auth.pm so the fallback never grows unbounded).
has '_local_last_gc' => (
    is      => 'rw',
    default => sub { time() },
);

has '_local_gc_interval' => (
    is      => 'ro',
    default => sub { 60 },
);

sub _build_redis {
    my ($self) = @_;

    return undef unless defined $self->redis_url && $self->redis_url ne '';

    my $redis;
    eval {
        require Mojo::Redis;
        $redis = Mojo::Redis->new($self->redis_url);
        # Blocking round-trip: confirms the server is actually reachable before
        # we start routing security decisions through it.
        $redis->db->ping;
        $self->_redis_available(1);
        1;
    } or do {
        warn "Store::Counter: Redis unavailable ($@), using in-memory fallback\n";
        $self->_redis_available(0);
        return undef;
    };

    return $redis;
}

# ----------------------------------------------------------------------------
# incr($key, $ttl_seconds) -> new integer count
#
# Redis path (atomic across workers/replicas):
#     INCR   key            # atomic; creates key at 1 if absent
#     EXPIRE key $ttl        # ONLY when INCR returned 1 (first hit)
#
# EXPIRE is applied only on the first increment so the window is FIXED (starts
# at the first hit, expires $ttl later) rather than sliding — this matches the
# pre-existing in-memory semantics exactly. INCR is atomic, so concurrent
# workers can never double-count or skip a count.
# ----------------------------------------------------------------------------
sub incr {
    my ($self, $key, $ttl) = @_;
    $ttl //= 60;

    if ($self->_use_redis) {
        my $count;
        my $ok = eval {
            my $db = $self->_redis->db;
            $count = $db->incr($key);
            $db->expire($key, $ttl) if defined $count && $count == 1;
            1;
        };
        return $count if $ok && defined $count;
        $self->_mark_down($@);
        # fall through to local on Redis failure (fail-open degradation)
    }

    return $self->_local_incr($key, $ttl);
}

# get($key) -> current integer count (0 if absent/expired)
sub get {
    my ($self, $key) = @_;

    if ($self->_use_redis) {
        my $val;
        my $ok = eval {
            $val = $self->_redis->db->get($key);
            1;
        };
        return ($val // 0) + 0 if $ok;
        $self->_mark_down($@);
    }

    return $self->_local_get($key);
}

# del($key) -> remove the counter (used by lockout reset on successful login)
sub del {
    my ($self, $key) = @_;

    if ($self->_use_redis) {
        my $ok = eval { $self->_redis->db->del($key); 1; };
        $self->_mark_down($@) unless $ok;
    }

    # Always clear the local copy too, so state can never linger after a reset.
    delete $self->_local->{$key};
    return 1;
}

# True when this store is backed by a live Redis connection.
sub is_shared {
    my ($self) = @_;
    return $self->_use_redis ? 1 : 0;
}

# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

sub _use_redis {
    my ($self) = @_;
    return 0 unless defined $self->redis_url && $self->redis_url ne '';
    # Touch the lazy builder once; afterwards rely on the availability flag.
    my $redis = $self->_redis;
    return $self->_redis_available && defined $redis ? 1 : 0;
}

sub _mark_down {
    my ($self, $err) = @_;
    return if !$self->_redis_available;
    warn "Store::Counter: Redis operation failed ($err), degrading to in-memory\n";
    $self->_redis_available(0);
    return;
}

sub _local_incr {
    my ($self, $key, $ttl) = @_;
    my $now = time();
    $self->_local_gc($now);

    my $entry = $self->_local->{$key};
    if (!$entry || $entry->{expires_at} <= $now) {
        # Fresh window (fixed, starts now, expires $ttl later).
        $entry = $self->_local->{$key} = { count => 0, expires_at => $now + $ttl };
    }
    return ++$entry->{count};
}

sub _local_get {
    my ($self, $key) = @_;
    my $entry = $self->_local->{$key};
    return 0 if !$entry || $entry->{expires_at} <= time();
    return $entry->{count};
}

# Purge expired local entries at most once per interval (amortised O(1) per
# call, O(n) scan only when the interval elapses).
sub _local_gc {
    my ($self, $now) = @_;
    $now //= time();
    return if $now - $self->_local_last_gc < $self->_local_gc_interval;
    my $local = $self->_local;
    for my $k (keys %$local) {
        delete $local->{$k} if $local->{$k}{expires_at} <= $now;
    }
    $self->_local_last_gc($now);
    return;
}

1;

__END__

=head1 NAME

Purl::Store::Counter - Shared (Redis-backed) counter with in-memory fallback

=head1 SYNOPSIS

    my $store = Purl::Store::Counter->new(redis_url => $ENV{PURL_REDIS_URL} // '');

    my $count = $store->incr("rl:$ip:$window", 120);   # atomic, shared
    my $used  = $store->get("rl:$ip:$window");
    $store->del("login:$username");                     # reset

=head1 DESCRIPTION

Backs security counters that must be consistent across prefork workers and
replicas. Under Redis it uses atomic C<INCR> plus a one-shot C<EXPIRE> (applied
only on the first increment) to implement a fixed expiry window without races.
Without a reachable Redis it falls back to a per-instance in-memory hash whose
behaviour is identical to the original Auth.pm implementation, so single-process
/ no-Redis deployments are entirely unaffected.

=head2 Failure policy (fail-open)

If Redis is configured but fails mid-operation, the store logs, flips
C<_redis_available> off, and serves the request from the in-memory fallback.
This keeps login and ingest available during a Redis outage rather than turning
a cache outage into a total auth outage; during the outage the counter degrades
to per-worker accounting (no worse than the pre-shared-store baseline).

=head1 REDIS COMMANDS

=over 4

=item * C<INCR key> - atomic increment, creates the key at 1 when absent

=item * C<EXPIRE key ttl> - applied ONLY when INCR returned 1 (fixed window)

=item * C<GET key> - read current count (nil => 0)

=item * C<DEL key> - reset a counter

=back

=cut

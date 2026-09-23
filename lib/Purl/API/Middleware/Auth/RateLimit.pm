package Purl::API::Middleware::Auth::RateLimit;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);
use Purl::Store::Counter;
use Purl::Util::Principal qw(principal_via principal_user);
use namespace::clean;

# Shared counter store (Redis-backed across prefork workers, in-memory fallback).
# Backs BOTH rate limiting and per-username login lockout so the limits are
# correct regardless of worker count. With no Redis configured it is a pure
# in-memory store, behaviour-identical to the original per-worker hashrefs.
has 'counter_store' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_counter_store',
);

sub _build_counter_store {
    my ($self) = @_;
    my $redis = $self->config->{redis} // {};
    # Resolve URL/mode the same way the broadcaster does: ENV overrides config.
    my $url  = $ENV{PURL_REDIS_URL}      // $redis->{url}  // '';
    my $mode = $ENV{PURL_BROADCAST_MODE} // $redis->{mode} // 'auto';
    # mode=local => never use Redis for counters (explicit single-node opt-out).
    $url = '' if $mode eq 'local';
    return Purl::Store::Counter->new(redis_url => $url);
}

has 'rate_limit_window' => (
    is      => 'ro',
    default => 60,
);

has 'rate_limit_max' => (
    is      => 'ro',
    default => 1000,
);

# ============================================
# Rate Limiting
# ============================================

sub _rate_limit_key {
    my ($self, $ip) = @_;
    my $window       = $self->rate_limit_window;
    my $window_start = int(time() / $window) * $window;
    return "rl:$ip:$window_start";
}

sub check_rate_limit {
    my ($self, $ip) = @_;
    # Atomic increment in the shared store; key rotates every window so old
    # windows expire on their own (Redis TTL / local GC). Give the key a TTL of
    # 2x the window so it survives its own window with margin.
    my $count = $self->counter_store->incr(
        $self->_rate_limit_key($ip),
        $self->rate_limit_window * 2,
    );
    return $count <= $self->rate_limit_max;
}

# Seconds until the current (clock-aligned) global window rolls over. The key
# TTL is 2x the window, so it is computed from the clock, not read from the store.
sub rate_limit_retry_after {
    my ($self) = @_;
    my $window = $self->rate_limit_window;
    my $left   = $window - (time() - int(time() / $window) * $window);
    return $left >= 1 ? int($left) : 1;
}

sub get_rate_limit_remaining {
    my ($self, $ip) = @_;
    my $used = $self->counter_store->get($self->_rate_limit_key($ip));
    return $self->rate_limit_max - $used;
}

# ============================================
# Per-User AI Rate Limiting
# ============================================
#
# The LLM-backed endpoints spend a paid provider budget, so a signed-in user
# gets ai.rate_limit (PURL_AI_RATE_LIMIT) calls per window on top of the global
# per-IP limit. Same shared store and fixed-window-from-first-hit shape as the
# login lockout (Purl::API::Middleware::Auth::LoginLockout). Without a session
# (API key, or an open instance where nobody signs in) the caller is keyed by
# client IP. 0 disables the limit.

my $AI_RATE_LIMIT_DEFAULT = 20;

has 'ai_rate_limit_window' => (
    is      => 'ro',
    default => 60,
);

# Invalid values already warned about, so a bad setting is reported once per
# distinct value (per worker), not on every AI request.
my %AI_RATE_LIMIT_WARNED;

# Read live so a settings/ENV change applies without a restart. Anything but a
# non-negative integer (e.g. -1, 5.5, "20/min") falls back to the default.
sub ai_rate_limit_max {
    my ($self) = @_;
    my $max = $self->settings ? $self->settings->get('ai', 'rate_limit') : undef;
    return $AI_RATE_LIMIT_DEFAULT unless defined $max;
    return $1 + 0 if $max =~ /^\s*(\d+)\s*$/;
    warn "Invalid ai.rate_limit / PURL_AI_RATE_LIMIT '$max' "
       . "(expected a non-negative integer); using $AI_RATE_LIMIT_DEFAULT\n"
        unless $AI_RATE_LIMIT_WARNED{$max}++;
    return $AI_RATE_LIMIT_DEFAULT;
}

sub _ai_rate_limit_key {
    my ($self, $c) = @_;
    my $username = principal_via($c) eq 'session' ? principal_user($c) : undef;
    return defined $username && length $username
        ? "ai:user:$username"
        : 'ai:ip:' . $self->client_ip($c);
}

sub check_ai_rate_limit {
    my ($self, $c) = @_;
    my $max = $self->ai_rate_limit_max;
    return 1 unless $max;
    my $count = $self->counter_store->incr(
        $self->_ai_rate_limit_key($c), $self->ai_rate_limit_window,
    );
    return $count <= $max;
}

# Seconds left in the caller's AI window (at least 1).
sub ai_rate_limit_retry_after {
    my ($self, $c) = @_;
    my $left = $self->counter_store->ttl($self->_ai_rate_limit_key($c));
    return $left >= 1 ? $left : 1;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth::RateLimit - global per-IP and per-user AI rate
limits on the shared counter store, for Purl::API::Middleware::Auth

=head1 DESCRIPTION

Owns C<counter_store> (also used by the login lockout and the Prometheus
counters). Relies on the consuming class for C<config>, C<settings> and
C<client_ip>.

=cut

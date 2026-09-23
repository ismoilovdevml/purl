package Purl::API::Middleware::Auth::CSRF;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes qw(time);
use Purl::Util::Random qw(random_hex);
use Purl::Util::Principal qw(principal_via);
use namespace::clean;

# CSRF enforcement toggle (security.csrf_enabled). Default on.
has 'csrf_enabled' => (
    is      => 'rw',
    default => 1,
);

sub _generate_secure_token {
    return random_hex(32);
}

# CSRF token HMAC secret.
#
# CRITICAL: this value MUST be identical across every prefork worker and every
# replica. generate_csrf_token() may run on worker A while verify_csrf_token()
# runs on worker B (session cookies are shared via app->secrets, so the browser
# replays a token minted by any worker). A per-worker random secret makes ~75%
# of browser mutations 403 under 4 workers, and ~always across replicas.
#
# Resolution order (first SHARED source wins):
#   1. PURL_CSRF_SECRET env — an explicit, dedicated shared secret.
#   2. Derived from the shared session secret (PURL_SESSION_SECRET env, or the
#      persisted server.session_secret in config that Server.pm also feeds to
#      app->secrets) via HMAC-SHA256 with a fixed label. HMAC means the CSRF
#      secret is NOT literally equal to the cookie-signing secret, yet is
#      deterministic and identical on every worker/replica that shares it.
#   3. Fallback: per-instance random token. Correct ONLY for a single process
#      with no shared secret configured (dev). Under prefork/multi-replica this
#      reintroduces the 403 bug, so operators must set one of the above.
has 'csrf_secret' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_csrf_secret',
);

sub _build_csrf_secret {
    my ($self) = @_;

    # 1. Dedicated explicit secret.
    my $explicit = $ENV{PURL_CSRF_SECRET};
    return $explicit if defined $explicit && length $explicit;

    # 2. Derive deterministically from the shared session secret.
    my $server_cfg     = $self->config->{server} // {};
    my $session_secret = $ENV{PURL_SESSION_SECRET} // $server_cfg->{session_secret};
    if (defined $session_secret && length $session_secret) {
        # Fixed label keyed by the session secret => a distinct value that is
        # still identical across all workers/replicas sharing that secret.
        return hmac_sha256_hex('purl:csrf-token-secret:v1', $session_secret);
    }

    # 3. No shared secret anywhere: single-process dev fallback.
    return _generate_secure_token();
}

# ============================================
# CSRF Token Management
# ============================================

sub generate_csrf_token {
    my ($self, $session_id) = @_;
    $session_id //= _generate_secure_token();
    my $timestamp = int(time() / 3600);  # Valid for 1 hour
    my $token = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return "$session_id:$timestamp:$token";
}

sub verify_csrf_token {
    my ($self, $token) = @_;
    return 0 unless $token && $token =~ /^([^:]+):(\d+):([a-f0-9]+)$/;
    my ($session_id, $timestamp, $hash) = ($1, $2, $3);
    my $current = int(time() / 3600);

    # Token valid for 2 hours
    return 0 if abs($current - $timestamp) > 2;
    my $expected = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return $hash eq $expected;
}

# ============================================
# CSRF Protection Middleware
# ============================================

sub check_csrf {
    my ($self, $c) = @_;

    # Globally disabled (security.csrf_enabled = 0)
    return 1 unless $self->csrf_enabled;

    # Only mutating methods can perform a state change.
    my $method = $c->req->method;
    return 1 unless $method =~ /^(?:POST|PUT|PATCH|DELETE)$/;

    # CSRF only threatens requests authorised by the ambient session cookie.
    # Programmatic clients (API key, bearer, basic) authenticate per request and
    # are exempt — but only when that credential is what check_auth accepted:
    # the mere presence of an X-API-Key or Basic header no longer waives the
    # token for a request the session cookie authorised.
    return 1 unless principal_via($c) eq 'session';

    # Cookie-authenticated browser request: a valid CSRF token is mandatory.
    my $csrf_token = $c->req->headers->header('X-CSRF-Token') // '';
    return $self->verify_csrf_token($csrf_token);
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth::CSRF - CSRF token issue/verify and the
cookie-request CSRF gate for Purl::API::Middleware::Auth

=head1 DESCRIPTION

Relies on the consuming class for C<config> (to derive the shared secret).

=cut

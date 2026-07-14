package Purl::API::Middleware::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use MIME::Base64 qw(decode_base64 encode_base64);
use Time::HiRes qw(time);
use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 de_base64);
use Purl::Util::ClientIP qw(resolve_client_ip);
use Purl::Store::Counter;

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

# Trusted reverse-proxy list (arrayref of CIDRs/IPs). Empty => never trust XFF.
has 'trusted_proxies' => (
    is      => 'rw',
    default => sub { [] },
);

# CSRF enforcement toggle (security.csrf_enabled). Default on.
has 'csrf_enabled' => (
    is      => 'rw',
    default => 1,
);

sub _generate_secure_token {
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, my $bytes, 32);
        close($fh);
        return unpack('H*', $bytes);
    }
    require Digest::SHA;
    return Digest::SHA::sha256_hex(time() . $$ . rand() . $$);
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

# License middleware reference for plan-aware auth
has 'license_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

# Settings reference for user lookup
has 'settings' => (
    is      => 'rw',
    default => sub { undef },
);

# ============================================
# Password Hashing
# ============================================

sub _generate_bcrypt_salt {
    my $bytes = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 16);
        close($fh);
    } else {
        $bytes = pack('C*', map { int(rand(256)) } 1..16);
    }
    return en_base64($bytes);
}

sub hash_password {
    my ($self, $password, $salt) = @_;
    return undef if !defined $password || length($password) < 8;
    $salt //= _generate_bcrypt_salt();
    my $hash = bcrypt_hash({
        key_nul => 1,
        cost    => 12,
        salt    => de_base64($salt),
    }, $password);
    return '$2b$12$' . $salt . en_base64($hash);
}

sub verify_password {
    my ($self, $password, $stored) = @_;
    return (0, undef) unless defined $password && length($password);

    # Bcrypt format: $2b$12$<22-char-salt><31-char-hash>
    if ($stored && $stored =~ /^\$2[aby]\$(\d{2})\$(.{22})(.+)$/) {
        my ($cost, $salt, $hash) = ($1, $2, $3);
        my $check = bcrypt_hash({
            key_nul => 1,
            cost    => $cost,
            salt    => de_base64($salt),
        }, $password);
        my $check_hash = en_base64($check);
        # Constant-time comparison
        return (0, undef) unless length($check_hash) == length($hash);
        my $result = 0;
        $result |= ord(substr($check_hash, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check_hash)-1;
        return ($result == 0, undef);
    }

    # Legacy SHA256 format: salt$hexhash — verify and migrate to bcrypt
    if ($stored && $stored =~ /^([^\$]+)\$([a-f0-9]+)$/) {
        my ($salt, $hash) = ($1, $2);
        my $check = sha256_hex($salt . $password . $salt);
        return (0, undef) unless length($check) == length($hash);
        my $result = 0;
        $result |= ord(substr($check, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check)-1;
        if ($result == 0) {
            # Migration: re-hash with bcrypt
            my $new_hash = $self->hash_password($password);
            return (1, $new_hash);
        }
        return (0, undef);
    }

    return (0, undef);
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

sub get_rate_limit_remaining {
    my ($self, $ip) = @_;
    my $used = $self->counter_store->get($self->_rate_limit_key($ip));
    return $self->rate_limit_max - $used;
}

# ============================================
# Per-Username Login Rate Limiting
# ============================================

my $USERNAME_RATE_LIMIT_MAX    = 5;
my $USERNAME_RATE_LIMIT_WINDOW = 600;

sub _login_key {
    my ($self, $username) = @_;
    return "login:$username";
}

sub check_username_rate_limit {
    my ($self, $username) = @_;
    return 1 unless defined $username && length($username);
    # Read-only: how many failures have accrued in the current fixed window.
    my $count = $self->counter_store->get($self->_login_key($username));
    return $count < $USERNAME_RATE_LIMIT_MAX;
}

sub record_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    # Atomic increment shared across workers; TTL sets a fixed 10-min window
    # that starts at the first failure (EXPIRE applied only on the 1st incr).
    $self->counter_store->incr($self->_login_key($username), $USERNAME_RATE_LIMIT_WINDOW);
    return;
}

sub reset_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    $self->counter_store->del($self->_login_key($username));
    return;
}

# ============================================
# Authentication Check
# ============================================

sub check_auth {
    my ($self, $c) = @_;
    my $auth_config = $self->config->{auth} // {};

    # Check if auth is enabled
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;

    # API Key auth always works (programmatic access)
    if ($self->_check_api_key($c, $auth_config)) {
        return 1;
    }

    # Basic auth always works
    if ($self->_check_basic_auth($c, $auth_config)) {
        $c->stash(current_user => 'api');
        return 1;
    }

    # Auth disabled entirely => open instance (no credentials configured).
    return 1 unless $auth_enabled;

    # Otherwise a valid session cookie is REQUIRED — regardless of license plan.
    # There is deliberately no Origin/Referer "same-origin" bypass: those headers
    # are attacker-controlled and must never grant access.
    return 1 if $self->_check_session($c);

    return 0;
}

sub _check_session {
    my ($self, $c) = @_;
    my $username = $c->session->{username};
    my $logged_in = $c->session->{logged_in};

    if ($logged_in && $username) {
        $c->stash(current_user => $username);
        return 1;
    }
    return 0;
}

sub _check_api_key {
    my ($self, $c, $auth_config) = @_;

    my $api_key = $c->req->headers->header('X-API-Key');
    return 0 unless $api_key;

    # Check ENV API keys (comma-separated)
    if (my $env_keys = $ENV{PURL_API_KEYS}) {
        my @keys = split /,/, $env_keys;
        return 1 if grep { $_ eq $api_key } @keys;
    }

    # Check config API keys (supports both plain strings and hash entries)
    my $valid_keys = $auth_config->{api_keys} // [];
    for my $entry (@$valid_keys) {
        my $stored = ref $entry eq 'HASH' ? ($entry->{key} // '') : $entry;
        return 1 if $stored eq $api_key;
    }

    return 0;
}

sub _check_basic_auth {
    my ($self, $c, $auth_config) = @_;

    my $auth_header = $c->req->headers->authorization // '';
    return 0 unless $auth_header =~ /^Basic\s+(.+)$/;

    my $decoded = decode_base64($1);
    my ($user, $pass) = split /:/, $decoded, 2;
    return 0 unless defined $user && defined $pass;

    my $users = $auth_config->{users} // {};
    return 0 unless exists $users->{$user};

    my $entry = $users->{$user};
    my $stored = ref $entry eq 'HASH' ? $entry->{password} : $entry;

    # Bcrypt or legacy SHA256 hash
    if ($stored && ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/)) {
        my ($valid, $new_hash) = $self->verify_password($pass, $stored);
        # Auto-migrate hash if needed (basic auth won't save, but login will)
        return $valid;
    }

    # Legacy plaintext (log warning in caller)
    return $stored eq $pass;
}

# ============================================
# API Key Reload
# ============================================

sub reload_api_keys {
    my ($self) = @_;
    return unless $self->settings;
    my $auth_section = $self->settings->get_section('auth') // {};
    $self->config->{auth}{api_keys} = $auth_section->{api_keys} // [];
    return 1;
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

    # Programmatic clients authenticate per-request (no ambient cookie), so they
    # are NOT vulnerable to CSRF and MUST be exempt (log ingestion, API automation).
    return 1 if $c->req->headers->header('X-API-Key');
    return 1 if ($c->req->headers->authorization // '') =~ /^Basic\s+/i;

    # CSRF only threatens requests authorised by an ambient session cookie.
    # No active session => nothing for an attacker to ride on => exempt.
    return 1 unless $c->session->{logged_in};

    # Cookie-authenticated browser request: a valid CSRF token is mandatory.
    my $csrf_token = $c->req->headers->header('X-CSRF-Token') // '';
    return $self->verify_csrf_token($csrf_token);
}

# Resolve the real client IP, honouring X-Forwarded-For only when the socket
# peer is a configured trusted proxy. See Purl::Util::ClientIP.
sub client_ip {
    my ($self, $c) = @_;
    my $peer = $c->tx->remote_address // '127.0.0.1';
    my $trusted = $self->trusted_proxies;
    return $peer unless $trusted && @$trusted;
    return resolve_client_ip(
        peer            => $peer,
        forwarded_for   => $c->req->headers->header('X-Forwarded-For'),
        trusted_proxies => $trusted,
    );
}

# ============================================
# Mojolicious Middleware Integration
# ============================================

sub apply_to_app {
    my ($self, $app, %options) = @_;
    my $skip_paths = $options{skip_paths} // [qr{^/api/(health|metrics)$}];

    $app->hook(before_dispatch => sub {
        my ($c) = @_;
        my $path = $c->req->url->path->to_string;

        # Skip configured paths
        for my $pattern (@$skip_paths) {
            return if $path =~ $pattern;
        }

        # Rate limiting
        my $ip = $self->client_ip($c);
        unless ($self->check_rate_limit($ip)) {
            $c->render(json => {
                error       => 'Rate limit exceeded',
                retry_after => $self->rate_limit_window,
            }, status => 429);
            return;
        }

        # Add rate limit headers
        $c->res->headers->header('X-RateLimit-Limit' => $self->rate_limit_max);
        $c->res->headers->header('X-RateLimit-Remaining' => $self->get_rate_limit_remaining($ip));
    });
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth - Authentication, CSRF, and Rate Limiting

=head1 SYNOPSIS

    use Purl::API::Middleware::Auth;

    my $auth = Purl::API::Middleware::Auth->new(
        config         => $config,
        rate_limit_max => 1000,
    );

    # Check authentication
    if ($auth->check_auth($c)) {
        # Authenticated
    }

    # Generate CSRF token
    my $token = $auth->generate_csrf_token();

    # Verify CSRF token
    if ($auth->verify_csrf_token($token)) {
        # Valid
    }

    # Rate limiting
    if ($auth->check_rate_limit($ip)) {
        # Within limits
    }

    # Hash password
    my $hash = $auth->hash_password('secret123');

=head1 METHODS

=head2 Authentication

=over 4

=item * check_auth($c) - Check if request is authenticated

=item * hash_password($password, $salt) - Hash a password

=item * verify_password($password, $stored) - Verify password hash

=back

=head2 CSRF Protection

=over 4

=item * generate_csrf_token($session_id) - Generate new CSRF token

=item * verify_csrf_token($token) - Verify CSRF token validity

=item * check_csrf($c) - Check if CSRF token is required and valid

=back

=head2 Rate Limiting

=over 4

=item * check_rate_limit($ip) - Check if IP is within rate limits

=item * get_rate_limit_remaining($ip) - Get remaining requests for IP

=back

=cut

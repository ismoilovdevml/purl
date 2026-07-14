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

# CSRF token secret (generated once per instance using /dev/urandom)
has 'csrf_secret' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { _generate_secure_token() },
);

# Per-username failed login tracking: { username => { count => N, window_start => T } }
has '_failed_login_attempts' => (
    is      => 'rw',
    default => sub { {} },
);

has '_failed_login_cleanup' => (
    is      => 'rw',
    default => sub { time() },
);

# Rate limiting state
has '_rate_limit' => (
    is      => 'rw',
    default => sub { {} },
);

has '_last_cleanup' => (
    is      => 'rw',
    default => sub { time() },
);

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

sub check_rate_limit {
    my ($self, $ip) = @_;
    my $now = time();
    my $window_start = int($now / $self->rate_limit_window) * $self->rate_limit_window;
    my $key = "$ip:$window_start";
    my $rate_limit = $self->_rate_limit;

    # Periodic cleanup - only once per window instead of every request (O(n) -> O(1) amortized)
    if ($now - $self->_last_cleanup >= $self->rate_limit_window) {
        for my $k (keys %$rate_limit) {
            delete $rate_limit->{$k} if $k !~ /:$window_start$/;
        }
        $self->_last_cleanup($now);
    }

    $rate_limit->{$key}++;
    return $rate_limit->{$key} <= $self->rate_limit_max;
}

sub get_rate_limit_remaining {
    my ($self, $ip) = @_;
    my $now = time();
    my $window_start = int($now / $self->rate_limit_window) * $self->rate_limit_window;
    my $key = "$ip:$window_start";
    my $used = $self->_rate_limit->{$key} // 0;
    return $self->rate_limit_max - $used;
}

# ============================================
# Per-Username Login Rate Limiting
# ============================================

my $USERNAME_RATE_LIMIT_MAX    = 5;
my $USERNAME_RATE_LIMIT_WINDOW = 600;

sub _cleanup_failed_login_attempts {
    my ($self) = @_;
    my $now = time();
    return if $now - $self->_failed_login_cleanup < $USERNAME_RATE_LIMIT_WINDOW;
    my $attempts = $self->_failed_login_attempts;
    for my $username (keys %$attempts) {
        delete $attempts->{$username}
            if $now - $attempts->{$username}{window_start} >= $USERNAME_RATE_LIMIT_WINDOW;
    }
    $self->_failed_login_cleanup($now);
}

sub check_username_rate_limit {
    my ($self, $username) = @_;
    return 1 unless defined $username && length($username);
    $self->_cleanup_failed_login_attempts();
    my $now   = time();
    my $entry = $self->_failed_login_attempts->{$username};
    return 1 unless $entry;
    if ($now - $entry->{window_start} >= $USERNAME_RATE_LIMIT_WINDOW) {
        delete $self->_failed_login_attempts->{$username};
        return 1;
    }
    return $entry->{count} < $USERNAME_RATE_LIMIT_MAX;
}

sub record_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    my $now      = time();
    my $attempts = $self->_failed_login_attempts;
    if (!$attempts->{$username} || $now - $attempts->{$username}{window_start} >= $USERNAME_RATE_LIMIT_WINDOW) {
        $attempts->{$username} = { count => 1, window_start => $now };
    } else {
        $attempts->{$username}{count}++;
    }
}

sub reset_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    delete $self->_failed_login_attempts->{$username};
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

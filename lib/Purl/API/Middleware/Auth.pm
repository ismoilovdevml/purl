package Purl::API::Middleware::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

# CSRF token secret (generated once per instance)
has 'csrf_secret' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..32) },
);

# Rate limiting state
has '_rate_limit' => (
    is      => 'rw',
    default => sub { {} },
);

has 'rate_limit_window' => (
    is      => 'ro',
    default => 60,
);

has 'rate_limit_max' => (
    is      => 'ro',
    default => 1000,
);

# ============================================
# Password Hashing
# ============================================

sub hash_password {
    my ($self, $password, $salt) = @_;
    $salt //= join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..16);
    my $hash = sha256_hex($salt . $password . $salt);
    return "$salt\$$hash";
}

sub verify_password {
    my ($self, $password, $stored) = @_;
    return 0 unless $stored && $stored =~ /^([^\$]+)\$([a-f0-9]+)$/;
    my ($salt, $hash) = ($1, $2);
    my $check = sha256_hex($salt . $password . $salt);

    # Constant-time comparison to prevent timing attacks
    return 0 unless length($check) == length($hash);
    my $result = 0;
    $result |= ord(substr($check, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check)-1;
    return $result == 0;
}

# ============================================
# CSRF Token Management
# ============================================

sub generate_csrf_token {
    my ($self, $session_id) = @_;
    $session_id //= join('', map { ('a'..'z', 0..9)[rand 36] } 1..16);
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

    # Cleanup old entries
    for my $k (keys %$rate_limit) {
        delete $rate_limit->{$k} if $k !~ /:$window_start$/;
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
# Authentication Check
# ============================================

sub check_auth {
    my ($self, $c) = @_;
    my $auth_config = $self->config->{auth} // {};

    # Check if auth is enabled
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;
    return 1 unless $auth_enabled;

    # Skip auth for same-origin requests (browser security)
    return 1 if $self->_is_same_origin($c);

    # Try API Key auth
    return 1 if $self->_check_api_key($c, $auth_config);

    # Try Basic auth
    return 1 if $self->_check_basic_auth($c, $auth_config);

    return 0;
}

sub _is_same_origin {
    my ($self, $c) = @_;

    # Sec-Fetch-Site header (modern browsers)
    my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
    return 1 if $sec_fetch eq 'same-origin' || $sec_fetch eq 'same-site';

    my $host = $c->req->headers->host // '';

    # Origin header check
    my $origin = $c->req->headers->header('Origin') // '';
    if ($origin && $host) {
        my ($origin_host) = $origin =~ m{^https?://([^/]+)};
        return 1 if $origin_host && $origin_host eq $host;
    }

    # Referer header fallback
    my $referer = $c->req->headers->header('Referer') // '';
    if ($referer && $host) {
        my ($referer_host) = $referer =~ m{^https?://([^/]+)};
        return 1 if $referer_host && $referer_host eq $host;
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

    # Check config API keys
    my $valid_keys = $auth_config->{api_keys} // [];
    return 1 if grep { $_ eq $api_key } @$valid_keys;

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

    my $stored = $users->{$user};

    # Hashed password (salt$hash format)
    if ($stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/) {
        return $self->verify_password($pass, $stored);
    }

    # Legacy plaintext (log warning in caller)
    return $stored eq $pass;
}

# ============================================
# CSRF Protection Middleware
# ============================================

sub check_csrf {
    my ($self, $c) = @_;
    my $method = $c->req->method;

    # Only check state-changing methods
    return 1 unless $method =~ /^(POST|PUT|DELETE)$/;

    # Skip for API key requests (programmatic access)
    return 1 if $c->req->headers->header('X-API-Key');

    # Only check same-origin requests (browser clients)
    my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
    return 1 unless $sec_fetch eq 'same-origin' || $sec_fetch eq 'same-site';

    my $csrf_token = $c->req->headers->header('X-CSRF-Token') // '';
    return $self->verify_csrf_token($csrf_token);
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
        my $ip = $c->tx->remote_address // '127.0.0.1';
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

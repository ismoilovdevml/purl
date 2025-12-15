package Purl::API::Middleware;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use MIME::Base64 qw(decode_base64 encode_base64);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(
    set_config
    hash_password
    verify_password
    generate_csrf_token
    verify_csrf_token
    check_auth
    check_rate_limit
    get_rate_limit_info
    cache_get
    cache_set
    cache_clear
    cache_size
);

# Configuration
my $config = {};

# CSRF secret (generated on first use)
my $csrf_secret;

# Rate limiting state
my %rate_limit;
my $rate_limit_window = 60;     # seconds
my $rate_limit_max    = 1000;   # requests per window

# In-memory cache
my %cache;
my $cache_ttl = 60;

# ============================================
# Configuration
# ============================================

sub set_config {
    my ($new_config) = @_;
    $config = $new_config // {};
    $cache_ttl = $config->{cache}{ttl} // 60;
    $rate_limit_max = $config->{rate_limit}{max_requests} // 1000;
    $rate_limit_window = $config->{rate_limit}{window} // 60;
    return 1;
}

sub _get_csrf_secret {
    $csrf_secret //= join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..32);
    return $csrf_secret;
}

# ============================================
# Password Hashing
# ============================================

sub hash_password {
    my ($password, $salt) = @_;
    $salt //= join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..16);
    my $hash = sha256_hex($salt . $password . $salt);
    return "$salt\$$hash";
}

sub verify_password {
    my ($password, $stored) = @_;
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
# CSRF Token
# ============================================

sub generate_csrf_token {
    my ($session_id) = @_;
    $session_id //= join('', map { ('a'..'z', 0..9)[rand 36] } 1..16);
    my $timestamp = int(time() / 3600);  # Valid for 1 hour
    my $token = hmac_sha256_hex("$session_id:$timestamp", _get_csrf_secret());
    return "$session_id:$timestamp:$token";
}

sub verify_csrf_token {
    my ($token) = @_;
    return 0 unless $token && $token =~ /^([^:]+):(\d+):([a-f0-9]+)$/;
    my ($session_id, $timestamp, $hash) = ($1, $2, $3);
    my $current = int(time() / 3600);

    # Token valid for 2 hours
    return 0 if abs($current - $timestamp) > 2;
    my $expected = hmac_sha256_hex("$session_id:$timestamp", _get_csrf_secret());
    return $hash eq $expected;
}

# ============================================
# Authentication
# ============================================

sub check_auth {
    my ($c) = @_;

    my $auth_config = $config->{auth} // {};

    # Check if auth is enabled via env or config
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;
    return 1 unless $auth_enabled;

    # Skip auth for requests from the web UI (same origin)
    # Sec-Fetch-Site is set by the browser and cannot be spoofed by JavaScript
    my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
    if ($sec_fetch eq 'same-origin' || $sec_fetch eq 'same-site') {
        return 1;
    }

    # Fallback for browsers that don't send Sec-Fetch-Site
    my $origin = $c->req->headers->header('Origin') // '';
    my $host = $c->req->headers->host // '';
    if ($origin && $host) {
        my ($origin_host) = $origin =~ m{^https?://([^/]+)};
        if ($origin_host && $origin_host eq $host) {
            return 1;
        }
    }

    # Fallback: Check Referer header
    my $referer = $c->req->headers->header('Referer') // '';
    if ($referer && $host) {
        my ($referer_host) = $referer =~ m{^https?://([^/]+)};
        if ($referer_host && $referer_host eq $host) {
            return 1;
        }
    }

    my $auth_header = $c->req->headers->authorization // '';

    # API Key auth (env or config)
    if (my $api_key = $c->req->headers->header('X-API-Key')) {
        # Check env API keys (comma-separated)
        if (my $env_keys = $ENV{PURL_API_KEYS}) {
            my @keys = split /,/, $env_keys;
            return 1 if grep { $_ eq $api_key } @keys;
        }
        # Check config API keys
        my $valid_keys = $auth_config->{api_keys} // [];
        return 1 if grep { $_ eq $api_key } @$valid_keys;
    }

    # Basic auth with hashed password support
    if ($auth_header =~ /^Basic\s+(.+)$/) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;

        my $users = $auth_config->{users} // {};
        if (exists $users->{$user}) {
            my $stored = $users->{$user};
            # Support hashed passwords (salt$hash format)
            if ($stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/) {
                return 1 if verify_password($pass, $stored);
            }
            # No plaintext support for security
        }
    }

    return 0;
}

# ============================================
# Rate Limiting
# ============================================

sub check_rate_limit {
    my ($ip) = @_;
    my $now = time();
    my $window_start = int($now / $rate_limit_window) * $rate_limit_window;

    my $key = "$ip:$window_start";

    # Cleanup old entries
    for my $k (keys %rate_limit) {
        delete $rate_limit{$k} if $k !~ /:$window_start$/;
    }

    $rate_limit{$key}++;
    return $rate_limit{$key} <= $rate_limit_max;
}

sub get_rate_limit_info {
    return {
        window => $rate_limit_window,
        max    => $rate_limit_max,
    };
}

# ============================================
# Cache
# ============================================

sub cache_get {
    my ($key) = @_;
    my $entry = $cache{$key};
    return unless $entry;
    return if $entry->{expires} < time();
    return $entry->{value};
}

sub cache_set {
    my ($key, $value, $ttl) = @_;
    $ttl //= $cache_ttl;
    $cache{$key} = {
        value   => $value,
        expires => time() + $ttl,
    };
    return $value;
}

sub cache_clear {
    %cache = ();
    return 1;
}

sub cache_size {
    return scalar keys %cache;
}

1;

__END__

=head1 NAME

Purl::API::Middleware - Authentication, rate limiting, CSRF protection, and caching

=head1 SYNOPSIS

    use Purl::API::Middleware qw(
        set_config
        check_auth
        check_rate_limit
        hash_password
        verify_password
        generate_csrf_token
        verify_csrf_token
        cache_get
        cache_set
        cache_clear
    );

    # Initialize with config
    set_config($config);

    # Password hashing
    my $hashed = hash_password('secret');
    my $valid = verify_password('secret', $hashed);

    # CSRF tokens
    my $token = generate_csrf_token();
    my $ok = verify_csrf_token($token);

    # Auth check in route
    return unless check_auth($c);

    # Rate limiting
    unless (check_rate_limit($ip)) {
        # Return 429
    }

    # Caching
    my $cached = cache_get($key);
    cache_set($key, $value, 60);

=head1 SECURITY FEATURES

=over 4

=item * SHA256 password hashing with random salt

=item * Constant-time password comparison (timing attack prevention)

=item * HMAC-based CSRF tokens with 2-hour expiry

=item * Same-origin request detection via Sec-Fetch-Site header

=item * Per-IP rate limiting with configurable window

=back

=cut

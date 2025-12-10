package Purl::API::Middleware;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);

our @EXPORT_OK = qw(
    check_auth
    check_rate_limit
    setup_cors
    cache_get
    cache_set
    cache_clear
);

# ============================================
# Authentication
# ============================================

my $config = {};
my %rate_limit;
my $rate_limit_window = 60;  # seconds
my $rate_limit_max = 1000;   # requests per window

# Simple in-memory cache
my %cache;
my $cache_ttl = 60;

sub set_config {
    my ($new_config) = @_;
    $config = $new_config // {};
    $cache_ttl = $config->{cache}{ttl} // 60;
    $rate_limit_max = $config->{rate_limit}{max_requests} // 1000;
}

sub check_auth {
    my ($c) = @_;

    my $auth_config = $config->{auth} // {};

    # Check if auth is enabled via env or config
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;
    return 1 unless $auth_enabled;

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

    # Basic auth
    if ($auth_header =~ /^Basic\s+(.+)$/) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;

        my $users = $auth_config->{users} // {};
        if (exists $users->{$user} && $users->{$user} eq $pass) {
            return 1;
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

sub get_rate_limit_window {
    return $rate_limit_window;
}

# ============================================
# Cache Helpers
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
}

sub cache_size {
    return scalar keys %cache;
}

sub get_cache_ttl {
    return $cache_ttl;
}

# ============================================
# CORS Setup
# ============================================

sub setup_cors {
    my ($c) = @_;
    $c->res->headers->header('Access-Control-Allow-Origin' => '*');
    $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
    $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key');
}

1;

__END__

=head1 NAME

Purl::API::Middleware - Authentication, rate limiting, and caching middleware

=head1 DESCRIPTION

This module provides middleware functions for the Purl API server.

=cut

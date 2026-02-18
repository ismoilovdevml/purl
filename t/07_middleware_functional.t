#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Middleware qw(
    check_auth check_rate_limit
    cache_get cache_set cache_clear
);

# ============================================
# Mock Mojo controller for check_auth
# ============================================
{
    package MockHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} }
    sub authorization { $_[0]->{h}{Authorization} }

    package MockReq;
    sub new { bless { headers => MockHeaders->new($_[1] // {}) }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new { bless { req => MockReq->new($_[1] // {}) }, $_[0] }
    sub req { $_[0]->{req} }
}

# ============================================
# check_auth — functional version
# ============================================
subtest 'check_auth disabled by default' => sub {
    local $ENV{PURL_AUTH_ENABLED} = 0;
    Purl::API::Middleware::set_config({});
    my $c = MockCtrl->new;
    ok check_auth($c), 'auth disabled = always passes';
};

subtest 'check_auth with API key from ENV' => sub {
    local $ENV{PURL_AUTH_ENABLED} = 1;
    local $ENV{PURL_API_KEYS} = 'testkey1,testkey2';
    Purl::API::Middleware::set_config({ auth => { enabled => 1 } });
    my $c = MockCtrl->new({ 'X-API-Key' => 'testkey1' });
    ok check_auth($c), 'valid API key passes';
};

subtest 'check_auth with invalid API key' => sub {
    local $ENV{PURL_AUTH_ENABLED} = 1;
    local $ENV{PURL_API_KEYS} = 'validkey';
    Purl::API::Middleware::set_config({ auth => { enabled => 1 } });
    my $c = MockCtrl->new({ 'X-API-Key' => 'wrongkey' });
    ok !check_auth($c), 'invalid API key fails';
};

subtest 'check_auth with basic auth' => sub {
    local $ENV{PURL_AUTH_ENABLED} = 1;
    delete $ENV{PURL_API_KEYS};
    Purl::API::Middleware::set_config({
        auth => {
            enabled => 1,
            users => { admin => 'secret' },
        },
    });
    require MIME::Base64;
    my $creds = MIME::Base64::encode_base64('admin:secret', '');
    my $c = MockCtrl->new({ Authorization => "Basic $creds" });
    ok check_auth($c), 'valid basic auth passes';
};

subtest 'check_auth with wrong basic auth' => sub {
    local $ENV{PURL_AUTH_ENABLED} = 1;
    delete $ENV{PURL_API_KEYS};
    Purl::API::Middleware::set_config({
        auth => {
            enabled => 1,
            users => { admin => 'secret' },
        },
    });
    require MIME::Base64;
    my $creds = MIME::Base64::encode_base64('admin:wrong', '');
    my $c = MockCtrl->new({ Authorization => "Basic $creds" });
    ok !check_auth($c), 'wrong basic auth fails';
};

# ============================================
# check_rate_limit — functional version
# ============================================
subtest 'rate_limit allows within limit' => sub {
    Purl::API::Middleware::set_config({ rate_limit => { max_requests => 5 } });
    # Use unique IP to avoid interference
    my $ip = '99.99.99.' . int(rand(255));
    for my $i (1..5) {
        ok check_rate_limit($ip), "request $i within limit";
    }
};

subtest 'rate_limit blocks over limit' => sub {
    Purl::API::Middleware::set_config({ rate_limit => { max_requests => 2 } });
    my $ip = '88.88.88.' . int(rand(255));
    check_rate_limit($ip) for 1..2;
    ok !check_rate_limit($ip), 'third request blocked';
};

# ============================================
# Cache helpers
# ============================================
subtest 'cache_set and cache_get' => sub {
    cache_clear();
    cache_set('mykey', { data => 42 }, 60);
    my $val = cache_get('mykey');
    is_deeply $val, { data => 42 }, 'retrieved cached value';
};

subtest 'cache_get miss' => sub {
    cache_clear();
    is cache_get('nonexistent'), undef, 'cache miss returns undef';
};

subtest 'cache_get TTL expiry' => sub {
    cache_clear();
    cache_set('expire', 'val', 0);  # 0-second TTL
    sleep 1;
    is cache_get('expire'), undef, 'expired entry returns undef';
};

subtest 'cache_clear empties cache' => sub {
    cache_set('a', 1, 60);
    cache_set('b', 2, 60);
    cache_clear();
    is cache_get('a'), undef, 'key a cleared';
    is cache_get('b'), undef, 'key b cleared';
};

subtest 'cache_size tracks entries' => sub {
    cache_clear();
    is Purl::API::Middleware::cache_size(), 0, 'empty cache';
    cache_set('x', 1, 60);
    is Purl::API::Middleware::cache_size(), 1, 'one entry';
    cache_set('y', 2, 60);
    is Purl::API::Middleware::cache_size(), 2, 'two entries';
};

done_testing;

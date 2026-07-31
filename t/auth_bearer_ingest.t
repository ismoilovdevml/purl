#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/lib";

use PurlTest::Mock qw(mock_auth_ctx);
use Purl::API::Middleware::Auth;
use Purl::Util::IngestRoutes qw(is_ingest_request);

# ============================================
# REGRESSION (issue #63): the kube-apiserver audit webhook is configured with a
# kubeconfig. A kubeconfig can present a bearer token or a client certificate —
# it CANNOT set an arbitrary header. _check_api_key only ever read X-API-Key,
# so with purl.authEnabled=true every POST /api/v1/k8s-audit was a 401 and the
# shipped deploy/k8s-audit/ config could never deliver a single event.
#
# Authorization: Bearer <key> is therefore accepted as an alternative transport
# for the SAME key material, on the ingest routes only.
# ============================================

my $KEY = 'ingest-key-abc123';

sub middleware {
    return Purl::API::Middleware::Auth->new(
        config => {
            auth => {
                enabled  => 1,
                api_keys => [ { key => $KEY, label => 'vector' } ],
                users    => {},
            },
        },
    );
}

sub ctx {
    my (%args) = @_;
    return mock_auth_ctx(
        method => $args{method} // 'POST',
        path   => $args{path}   // '/api/v1/k8s-audit',
        headers => $args{headers} // {},
        session => $args{session} // {},
    );
}

sub authed {
    my (%args) = @_;
    return middleware()->check_auth(ctx(%args)) ? 1 : 0;
}

# Auth must be ON for any of this to mean anything, and a stray PURL_API_KEYS
# in the developer's shell must not silently validate every key.
local $ENV{PURL_AUTH_ENABLED} = 1;
local $ENV{PURL_API_KEYS}     = undef;

# ============================================
# The gap that shipped
# ============================================
subtest 'bearer token authenticates the k8s audit webhook' => sub {
    is authed(headers => { Authorization => "Bearer $KEY" }), 1,
        'POST /api/v1/k8s-audit with Authorization: Bearer <key> is accepted';
};

subtest 'bearer token works on every ingest route' => sub {
    for my $path (qw(
        /api/logs
        /api/v1/otlp/logs
        /api/v1/syslog
        /api/v1/k8s-audit
    )) {
        is authed(path => $path, headers => { Authorization => "Bearer $KEY" }), 1,
            "POST $path accepts bearer";
    }
};

# ============================================
# A wrong key must still be a 401. Without this the whole change could
# degenerate into "accept anything with an Authorization header" unnoticed.
# ============================================
subtest 'a bearer token that is not a configured key is rejected' => sub {
    is authed(headers => { Authorization => 'Bearer not-a-real-key' }), 0,
        'unknown bearer key refused';
    is authed(headers => { Authorization => 'Bearer ' . uc $KEY }), 0,
        'the key itself is case-SENSITIVE';
    is authed(headers => { Authorization => "Bearer ${KEY}x" }), 0,
        'a prefix-extended key is refused (no partial match)';
    is authed(headers => { Authorization => 'Bearer ' . substr($KEY, 0, 5) }), 0,
        'a truncated key is refused';
};

subtest 'ENV-configured keys work over bearer too' => sub {
    local $ENV{PURL_API_KEYS} = 'env-key-1,env-key-2';
    is authed(headers => { Authorization => 'Bearer env-key-2' }), 1,
        'a PURL_API_KEYS entry is accepted as a bearer token';
    is authed(headers => { Authorization => 'Bearer env-key-3' }), 0,
        'a non-entry is still refused';
};

# ============================================
# RFC 7235: the auth-scheme token is case-insensitive, the credential is not.
# ============================================
subtest 'the Bearer scheme is case-insensitive' => sub {
    for my $scheme (qw(Bearer bearer BEARER BeArEr)) {
        is authed(headers => { Authorization => "$scheme $KEY" }), 1,
            "'$scheme' is recognised as the bearer scheme";
    }
};

# ============================================
# Malformed headers are 401, never a 500. Each of these must return a plain
# false from check_auth without throwing.
# ============================================
subtest 'malformed Authorization headers are refused, not fatal' => sub {
    my @malformed = (
        'Bearer',                  # scheme only, no credential
        'Bearer ',                 # trailing space, empty credential
        "Bearer  $KEY",            # two spaces => not a valid credential
        "Bearer\t$KEY",            # tab instead of SP
        "Bearerx $KEY",            # scheme is not "Bearer"
        "Bearer$KEY",              # no separator at all
        'Basic xxx',               # a different scheme
        'Basic',                   # a different scheme, truncated
        "Bearer $KEY extra",       # credential must be a single token
        '',                        # empty header
        ' ',                       # whitespace-only header
        'Bearer %%%',              # junk credential
    );

    for my $header (@malformed) {
        my $result = eval { middleware()->check_auth(ctx(headers => { Authorization => $header })) };
        is $@, '', sprintf('header %s does not die', _show($header));
        is $result ? 1 : 0, 0, sprintf('header %s is refused', _show($header));
    }
};

sub _show {
    my ($s) = @_;
    $s =~ s/\t/\\t/g;
    return "'$s'";
}

# ============================================
# No regression on the existing transport.
# ============================================
subtest 'X-API-Key still authenticates' => sub {
    is authed(headers => { 'X-API-Key' => $KEY }), 1, 'valid X-API-Key accepted';
    is authed(headers => { 'X-API-Key' => 'wrong' }), 0, 'invalid X-API-Key refused';
    is authed(path => '/api/settings', method => 'GET', headers => { 'X-API-Key' => $KEY }), 1,
        'X-API-Key is NOT restricted to ingest routes (unchanged behaviour)';
};

# ============================================
# Documented precedence: X-API-Key wins outright when present.
# ============================================
subtest 'X-API-Key takes precedence over Authorization: Bearer' => sub {
    is authed(headers => { 'X-API-Key' => $KEY, Authorization => 'Bearer garbage' }), 1,
        'valid X-API-Key wins over a bad bearer token';
    is authed(headers => { 'X-API-Key' => 'wrong', Authorization => "Bearer $KEY" }), 0,
        'a present-but-invalid X-API-Key is NOT rescued by a valid bearer token';
};

# ============================================
# Scope: bearer is an INGEST credential. Session-cookie dashboard routes and
# non-ingest verbs must not become reachable with an API key over Authorization.
# ============================================
subtest 'bearer does not open non-ingest routes' => sub {
    for my $path (qw(
        /api/settings
        /api/settings/users
        /api/auth/change-password
        /api/alerts
        /api/dashboards
        /api/query
        /api/es/_search
        /api/backup
    )) {
        is authed(path => $path, headers => { Authorization => "Bearer $KEY" }), 0,
            "POST $path is NOT reachable with a bearer token";
    }
};

subtest 'bearer does not open the log SEARCH route' => sub {
    is authed(method => 'GET', path => '/api/logs', headers => { Authorization => "Bearer $KEY" }), 0,
        'GET /api/logs (search) refuses bearer; only POST /api/logs ingests';
    is authed(method => 'GET', path => '/api/v1/k8s-audit', headers => { Authorization => "Bearer $KEY" }), 0,
        'GET on an ingest path refuses bearer';
};

subtest 'bearer does not fabricate a session' => sub {
    my $mw = middleware();
    my $c  = ctx(headers => { Authorization => "Bearer $KEY" });
    ok $mw->check_auth($c), 'authenticated';
    is $c->session->{logged_in}, undef, 'no session was created';
    is $c->session->{username},  undef, 'no username was set';
};

# ============================================
# The shared ingest-route predicate (one source of truth for Server.pm's
# ingest-bytes metric and this auth gate).
# ============================================
subtest 'is_ingest_request' => sub {
    ok is_ingest_request('POST', '/api/logs'),          'POST /api/logs';
    ok is_ingest_request('POST', '/api/v1/otlp/logs'),  'POST /api/v1/otlp/logs';
    ok is_ingest_request('POST', '/api/v1/syslog'),     'POST /api/v1/syslog';
    ok is_ingest_request('POST', '/api/v1/k8s-audit'),  'POST /api/v1/k8s-audit';
    ok is_ingest_request('POST', '/api/v1/k8s-audit/'), 'trailing slash matches the router';
    ok is_ingest_request('POST', '/api/_bulk'),         'POST /api/_bulk';
    ok is_ingest_request('POST', '/api/logs-2024/_bulk'), 'POST /api/<index>/_bulk';

    ok !is_ingest_request('GET',  '/api/logs'),           'GET /api/logs is a search';
    ok !is_ingest_request('POST', '/api/query'),          'POST /api/query is a search';
    ok !is_ingest_request('POST', '/api/settings'),       'settings is not ingest';
    ok !is_ingest_request('POST', '/api/logs/extra'),     'no prefix match';
    ok !is_ingest_request('POST', '/other/api/logs'),     'anchored at the start';
    ok !is_ingest_request('POST', undef),                 'undef path is not ingest';
    ok !is_ingest_request(undef,  '/api/logs'),           'undef method is not ingest';
};

done_testing();

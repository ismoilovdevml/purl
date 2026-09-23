#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);

# ============================================
# REGRESSION (#84): an unmatched /api/* request fell through to the SPA
# catch-all and came back as index.html (200 in production, 500 here where no
# web build exists). API clients got HTML where they expect JSON. Any method on
# an unknown /api path must be a JSON 404; non-API paths keep the SPA fallback.
# ============================================

my $DIR;
BEGIN {
    $DIR = "/tmp/purl_api_not_found_test_$$";
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'api-not-found-test-secret-0123456789abcdef';
    $ENV{PURL_CONFIG_FILE}     = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}      = $DIR;
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
}
make_path($DIR);
END { remove_tree($DIR) if $DIR }

{
    package Purl::Storage::InMemory;
    use Moo;
    sub flush        { 1 }
    sub maybe_flush  { }
    sub get_metrics  { { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 } }
    sub log_audit_event    { 1 }
    sub _init_audit_schema { 1 }
}

my $storage = Purl::Storage::InMemory->new;

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}

my $app = Purl::API::Server->create(config => { auth => { enabled => 1 } })->setup_routes;

use Test::Mojo;
my $t = Test::Mojo->new($app);

subtest 'unknown /api paths are a JSON 404 for every method' => sub {
    for my $case (
        [ get    => '/api/license' ],
        [ get    => '/api/does/not/exist' ],
        [ post   => '/api/nope' ],
        [ put    => '/api/nope/1' ],
        [ delete => '/api/nope/1' ],
        [ patch  => '/api/nope' ],
        [ get    => '/api' ],
        [ get    => '/api/' ],
    ) {
        my ($method, $path) = @$case;
        my $m = "${method}_ok";
        $t->$m($path)
          ->status_is(404, uc($method) . " $path is 404")
          ->content_type_like(qr{application/json}, 'as JSON')
          ->json_is('/error' => 'Not found', 'with the error body');
    }
};

subtest 'known /api routes are untouched' => sub {
    $t->get_ok('/api/health/live')->status_is(200);
    # A real protected route still hits the auth gate, not the 404.
    $t->get_ok('/api/logs')->status_is(401);
};

subtest 'non-API paths keep the SPA fallback' => sub {
    for my $path ('/', '/logs', '/settings/users') {
        $t->get_ok($path);
        my $json = $t->tx->res->json;
        ok !(ref $json eq 'HASH' && ($json->{error} // '') eq 'Not found'),
            "$path is not the API 404";
    }
};

done_testing;

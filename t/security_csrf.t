#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);

# ============================================
# Full-stack security tests (Test::Mojo):
#   (a) session-authenticated POST with NO CSRF token  => 403
#   (b) API-key ingest POST with NO CSRF token          => 200 (exempt)
#   (c) forged Origin/Referer header WITHOUT a session  => 401
#   plus: session POST WITH a valid CSRF token          => allowed
# ============================================

BEGIN {
    $ENV{PURL_AUTH_ENABLED}   = '1';                    # auth ON
    $ENV{PURL_API_KEYS}       = 'sec-ingest-key';
    $ENV{PURL_ADMIN_PASSWORD} = 'StrongAdminPass123';   # known, non-default
    $ENV{PURL_LDAP_ENABLED}   = '0';
    $ENV{PURL_SAML_ENABLED}   = '0';
    $ENV{PURL_SESSION_SECRET} = 'csrf-test-secret-key-abcdef0123456789';
    $ENV{PURL_CONFIG_FILE}    = "/tmp/purl_csrf_test_$$/settings.json";
    $ENV{PURL_CONFIG_DIR}     = "/tmp/purl_csrf_test_$$";
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
}

make_path($ENV{PURL_CONFIG_DIR});
# Expired trial => Free plan (proves CSRF is plan-independent)
{
    open my $fh, '>', "$ENV{PURL_CONFIG_DIR}/trial.json" or die $!;
    my $expired = time() - 86400;
    print $fh "{\"started_at\":@{[ $expired - 14*86400 ]},\"expires_at\":$expired}";
    close $fh;
}

# ============================================
# Minimal in-memory storage mock
# ============================================
{
    package Purl::Storage::InMemory;
    use Moo;
    has '_logs' => (is => 'rw', default => sub { [] });
    sub insert       { push @{$_[0]->_logs}, $_[1] }
    sub insert_batch { push @{$_[0]->_logs}, @{$_[1]} }
    sub flush        { 1 }
    sub maybe_flush  { }
    sub search       { [] }
    sub count        { 0 }
    sub stats        { { total_logs => 0, db_size_bytes => 0, db_size_mb => 0 } }
    sub field_stats  { [] }
    sub get_fields   { [qw(level service host message timestamp)] }
    sub get_metrics  { { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 } }
    sub _init_audit_schema { 1 }
    sub log_audit_event    { 1 }
    sub can { my ($s, $m) = @_; $s->SUPER::can($m) }
}

my $mock_storage = Purl::Storage::InMemory->new;

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $mock_storage };
}

my $server = Purl::API::Server->create(config => { auth => { enabled => 1 } });
my $app    = $server->setup_routes;

use Test::Mojo;

# --- login as admin to obtain a valid session cookie ---
my $t = Test::Mojo->new($app);
$t->post_ok('/api/auth/login',
    { 'Content-Type' => 'application/json' },
    json => { username => 'admin', password => 'StrongAdminPass123' })
  ->status_is(200)
  ->json_is('/authenticated' => 1);

# ============================================
# (a) session-authenticated mutating POST, NO CSRF token => 403
# ============================================
subtest '(a) session POST without CSRF token is rejected 403' => sub {
    $t->post_ok('/api/logs',
        { 'Content-Type' => 'application/json' },   # cookie sent automatically
        json => { level => 'INFO', message => 'via session', service => 'ui' })
      ->status_is(403)
      ->json_has('/error');
    like $t->tx->res->json->{error}, qr/CSRF/i, 'error mentions CSRF';
};

# ============================================
# session-authenticated POST WITH a valid CSRF token => allowed (not 403)
# proves the endpoint-issued token verifies against the enforcing middleware
# (single shared secret).
# ============================================
subtest 'session POST with valid CSRF token is accepted' => sub {
    $t->get_ok('/api/csrf-token')->status_is(200)->json_has('/csrf_token');
    my $token = $t->tx->res->json->{csrf_token};

    $t->post_ok('/api/logs',
        { 'Content-Type' => 'application/json', 'X-CSRF-Token' => $token },
        json => { level => 'INFO', message => 'via session+csrf', service => 'ui' })
      ->status_is(200)
      ->json_is('/inserted' => 1);
};

# ============================================
# (b) API-key ingest POST with NO CSRF token => 200 (exempt)
# ============================================
subtest '(b) API-key ingest without CSRF token still succeeds' => sub {
    my $before = scalar @{ $mock_storage->_logs };
    $t->post_ok('/api/logs',
        { 'Content-Type' => 'application/json', 'X-API-Key' => 'sec-ingest-key' },
        json => { level => 'INFO', message => 'via api key', service => 'agent' })
      ->status_is(200)
      ->json_is('/inserted' => 1);
    ok scalar(@{ $mock_storage->_logs }) > $before, 'log was ingested';
};

# ============================================
# (c) forged Origin/Referer WITHOUT a session => 401 (no bypass)
# ============================================
subtest '(c) forged same-origin headers do not grant access' => sub {
    my $anon = Test::Mojo->new($app);   # fresh cookie jar: no session
    $anon->get_ok('/api/logs' => {
            'Origin'         => 'http://localhost:3000',
            'Referer'        => 'http://localhost:3000/dashboard',
            'Sec-Fetch-Site' => 'same-origin',
        })
      ->status_is(401)
      ->json_has('/error');
};

subtest '(c2) forged Origin on a mutating request is also denied' => sub {
    my $anon = Test::Mojo->new($app);
    $anon->post_ok('/api/logs' => {
            'Content-Type'   => 'application/json',
            'Origin'         => 'http://localhost:3000',
            'Sec-Fetch-Site' => 'same-origin',
        },
        json => { level => 'INFO', message => 'forged', service => 'evil' })
      ->status_is(401);
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);

# ============================================================
# REGRESSION: /api/logs/stream must NOT be reachable anonymously.
#
# The live-tail WebSocket route used to hang off $api instead of $protected,
# so with auth ENABLED:
#     GET /api/logs         -> 401 Unauthorized      (correct)
#     GET /api/logs/stream  -> 101 Switching Protocols  (WRONG)
# i.e. any anonymous client got the full live log firehose.
#
# This file pins the contract:
#   1. no credentials             => handshake REFUSED (401, not 101)
#   2. valid session cookie       => handshake SUCCEEDS (the dashboard path;
#                                    browsers cannot set custom headers on a
#                                    WS handshake, so the cookie MUST work)
#   3. valid X-API-Key header     => handshake SUCCEEDS (programmatic clients)
#   4. bogus X-API-Key            => handshake REFUSED
#
# Without the fix, subtests 1 and 4 fail (they get 101 / is_websocket).
# ============================================================

BEGIN {
    $ENV{PURL_AUTH_ENABLED}   = '1';
    $ENV{PURL_API_KEYS}       = 'ws-test-key';
    $ENV{PURL_ADMIN_PASSWORD} = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}   = '0';
    $ENV{PURL_SAML_ENABLED}   = '0';
    $ENV{PURL_SESSION_SECRET} = 'ws-auth-test-secret-abcdef0123456789';
    $ENV{PURL_CONFIG_FILE}    = "/tmp/purl_ws_auth_test_$$/settings.json";
    $ENV{PURL_CONFIG_DIR}     = "/tmp/purl_ws_auth_test_$$";
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';
    $ENV{PURL_BROADCAST_MODE}  = 'local';
    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';   # no background timer noise
}

make_path($ENV{PURL_CONFIG_DIR});

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

# Attempt a WebSocket handshake and return the HTTP status the server
# answered it with: 101 == upgraded (stream granted), anything else == refused.
sub handshake_status {
    my ($t, %headers) = @_;
    my $tx = $t->ua->build_websocket_tx('/api/logs/stream', \%headers);
    $t->ua->start($tx);
    return $tx->res->code;
}

# ============================================
# 1. Anonymous handshake => REFUSED
# ============================================
subtest 'anonymous WebSocket handshake is refused' => sub {
    my $anon = Test::Mojo->new($app);   # fresh cookie jar: no session
    my $code = handshake_status($anon);

    isnt $code, 101, 'connection was NOT upgraded to a WebSocket';
    is   $code, 401, 'handshake answered 401 Unauthorized';
};

# ============================================
# 2. Valid session cookie => ACCEPTED (dashboard path).
#    Full round trip: the server must actually deliver the stream banner.
# ============================================
subtest 'session-authenticated WebSocket handshake succeeds' => sub {
    my $t = Test::Mojo->new($app);
    $t->post_ok('/api/auth/login',
        { 'Content-Type' => 'application/json' },
        json => { username => 'admin', password => 'StrongAdminPass123' })
      ->status_is(200)
      ->json_is('/authenticated' => 1);

    is handshake_status($t), 101, 'session cookie yields 101 Switching Protocols';

    $t->websocket_ok('/api/logs/stream')
      ->message_ok
      ->json_message_is('/type' => 'connected')
      ->finish_ok;
};

# ============================================
# 3. Valid API key header => ACCEPTED (programmatic clients)
# ============================================
subtest 'API-key WebSocket handshake succeeds' => sub {
    my $t = Test::Mojo->new($app);
    is handshake_status($t, 'X-API-Key' => 'ws-test-key'), 101,
        'valid X-API-Key yields 101 Switching Protocols';

    $t->websocket_ok('/api/logs/stream' => { 'X-API-Key' => 'ws-test-key' })
      ->message_ok
      ->json_message_is('/type' => 'connected')
      ->finish_ok;
};

# ============================================
# 4. Bogus API key => REFUSED
# ============================================
subtest 'invalid API key WebSocket handshake is refused' => sub {
    my $t = Test::Mojo->new($app);
    my $code = handshake_status($t, 'X-API-Key' => 'not-the-key');
    isnt $code, 101, 'bogus key does NOT upgrade to a WebSocket';
    is   $code, 401, 'handshake answered 401 Unauthorized';
};

# ============================================
# 5. Sanity: the plain REST sibling behaves the same way, so the two can
#    never diverge again (this is the asymmetry the audit caught).
# ============================================
subtest 'REST /api/logs and WS /api/logs/stream agree for anonymous callers' => sub {
    my $anon = Test::Mojo->new($app);
    $anon->get_ok('/api/logs')->status_is(401);
    is handshake_status($anon), 401,
        'WebSocket route rejects the same caller REST rejects';
};

done_testing;

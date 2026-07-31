#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use lib "$Bin/lib";
use File::Path qw(make_path);
use Mojo::JSON qw(encode_json);

# ============================================================================
# REGRESSION (#64): the live-tail WebSocket must speak the TYPED protocol the
# dashboard actually implements.
#
# The server used to answer a broadcast with one bare JSON array per batch:
#
#     $ws->send({json => \@matches});          # [ {...}, {...} ]
#
# while web/src/stores/logs.js dispatches on `data.type`:
#
#     if (data.type === 'pong') { ... }
#     if (data.type === 'log')  { logs.update(... data.data ...) }
#
# An array has no `type`, so every delivered frame was silently discarded and
# the live pane stayed empty. `$ws->send` appeared EXACTLY ONCE in Server.pm,
# which also means the server never answered the client's {"type":"ping"} —
# so logs.js kept `pongSupported = false` and disabled its liveness check
# entirely, leaving a dead socket undetected forever.
#
# The contract pinned here (server side of web/src/stores/logs.js):
#   * greeting            -> {"type":"connected", ...}
#   * client ping         -> {"type":"pong"}
#   * every matching log  -> {"type":"log","data":{ ...one log... }}  (ONE
#                            frame per log, never a batch array)
#
# Restore `$ws->send({json => \@matches})` and the "typed" subtests below fail.
# ============================================================================

BEGIN {
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_API_KEYS}        = 'tail-test-key';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'live-tail-protocol-secret-0123456789ab';
    $ENV{PURL_CONFIG_DIR}      = "/tmp/purl_live_tail_$$";
    $ENV{PURL_CONFIG_FILE}     = "/tmp/purl_live_tail_$$/settings.json";
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';
    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';   # no background timer noise
}

make_path($ENV{PURL_CONFIG_DIR});

use PurlTest::Mock qw(mock_server_storage);

my $mock_storage = mock_server_storage();

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $mock_storage };
}

my $server = Purl::API::Server->create(config => { auth => { enabled => 1 } });
my $app    = $server->setup_routes;

use Test::Mojo;

my %AUTH = ('X-API-Key' => 'tail-test-key');

# A second client on the SAME app: the WebSocket under test owns $t's user
# agent, so the ingest that feeds it has to come from somewhere else. Both
# wrap the same $app, hence the same in-process broadcaster.
sub ingest {
    my (@logs) = @_;
    my $in = Test::Mojo->new($app);
    $in->post_ok('/api/logs', { %AUTH, 'Content-Type' => 'application/json' },
        encode_json(\@logs))->status_is(200);
    return;
}

# ============================================
# 1. The greeting is typed (this part already worked — pinned so the
#    protocol cannot regress into a mix of typed and untyped frames).
# ============================================
subtest 'greeting frame carries type=connected' => sub {
    my $t = Test::Mojo->new($app);
    $t->websocket_ok('/api/logs/stream' => \%AUTH)
      ->message_ok
      ->json_message_is('/type' => 'connected')
      ->finish_ok;
};

# ============================================
# 2. ping -> pong. Without it logs.js never sets pongSupported and stops
#    checking liveness, so a half-open socket is never noticed.
# ============================================
subtest 'client ping is answered with a typed pong' => sub {
    my $t = Test::Mojo->new($app);
    $t->websocket_ok('/api/logs/stream' => \%AUTH)
      ->message_ok                              # greeting
      ->json_message_is('/type' => 'connected');

    $t->send_ok({ json => { type => 'ping' } })
      ->message_ok
      ->json_message_is('/type' => 'pong', 'server answers app-level ping')
      ->finish_ok;
};

# ============================================
# 3. An ingested log reaches the socket as {"type":"log","data":{...}}.
#    This is the frame logs.js consumes; a bare array is dropped.
# ============================================
subtest 'an ingested log arrives as a typed log frame' => sub {
    my $t = Test::Mojo->new($app);
    $t->websocket_ok('/api/logs/stream' => \%AUTH)
      ->message_ok
      ->json_message_is('/type' => 'connected');

    ingest({ message => 'tailmark one', level => 'ERROR', service => 'api' });

    $t->message_ok
      ->json_message_is('/type' => 'log', 'frame is typed as a log')
      ->json_message_is('/data/message' => 'tailmark one', 'log body under /data')
      ->json_message_is('/data/level'   => 'ERROR', 'level survives the trip')
      ->finish_ok;
};

# ============================================
# 4. ONE frame per log, not one array per batch. logs.js prepends
#    `data.data` as a single entry, so a batched array would collapse a
#    whole ingest into one unusable row.
# ============================================
subtest 'a batch of two logs arrives as two separate frames' => sub {
    my $t = Test::Mojo->new($app);
    $t->websocket_ok('/api/logs/stream' => \%AUTH)
      ->message_ok
      ->json_message_is('/type' => 'connected');

    ingest(
        { message => 'batch first',  level => 'INFO', service => 'api' },
        { message => 'batch second', level => 'WARN', service => 'api' },
    );

    $t->message_ok
      ->json_message_is('/type' => 'log')
      ->json_message_is('/data/message' => 'batch first', 'first log its own frame');

    $t->message_ok
      ->json_message_is('/type' => 'log')
      ->json_message_is('/data/message' => 'batch second', 'second log its own frame')
      ->finish_ok;
};

# ============================================
# 5. A subscribe filter still suppresses non-matching logs — the typed
#    rewrite must not turn the stream into an unfiltered firehose.
# ============================================
subtest 'subscribe filter suppresses non-matching logs' => sub {
    my $t = Test::Mojo->new($app);
    $t->websocket_ok('/api/logs/stream' => \%AUTH)
      ->message_ok
      ->json_message_is('/type' => 'connected');

    $t->send_ok({ json => { type => 'subscribe', filter => { level => 'ERROR' } } });

    # Round-trip a ping so the subscribe is definitely processed before the
    # ingest — otherwise a pass here could be a race rather than filtering.
    $t->send_ok({ json => { type => 'ping' } })
      ->message_ok
      ->json_message_is('/type' => 'pong');

    ingest(
        { message => 'filtered out', level => 'DEBUG', service => 'api' },
        { message => 'let through',  level => 'ERROR', service => 'api' },
    );

    $t->message_ok
      ->json_message_is('/type' => 'log')
      ->json_message_is('/data/message' => 'let through',
          'only the ERROR log was framed; the DEBUG one never arrived')
      ->finish_ok;
};

done_testing;

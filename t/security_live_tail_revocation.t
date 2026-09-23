#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

# ============================================
# REGRESSION (#91 security review, MINOR 5): an open live-tail WebSocket
# survived logout.
#
# /api/logs/stream is authenticated once, at the handshake. A socket opened
# before a logout (or password change, user deletion) kept streaming every
# ingested log for as long as it stayed open. It now re-checks its session
# every $SESSION_RECHECK_SECONDS against the live revocation stamps and closes
# with 4401 when the session is no longer valid.
# ============================================

use PurlTest::SessionApp qw(app login cookie_of admin_call);
use Test::Mojo;
use Mojo::IOLoop;
use Purl::API::Routes::LiveTail;

$Purl::API::Routes::LiveTail::SESSION_RECHECK_SECONDS = 0.2;

my $KEY = 'live-tail-key-0123456789';
$ENV{PURL_API_KEYS} = $KEY;

admin_call(post => '/api/settings/users',
    { username => 'alice', password => 'AlicePass12345', role => 'viewer' });

sub run_loop_for {
    my ($seconds) = @_;
    my $id = Mojo::IOLoop->timer($seconds => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
    Mojo::IOLoop->remove($id);
    return;
}

sub still_open {
    my ($t, $name) = @_;
    $t->send_ok({ json => { type => 'ping' } }, "$name: can still send")
      ->message_ok("$name: still answered")
      ->json_message_is('/type' => 'pong');
}

subtest 'a session socket is closed with 4401 after its logout' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);
    $t->websocket_ok('/api/logs/stream')->message_ok->json_message_is('/type' => 'connected');

    run_loop_for(0.5);
    still_open($t, 'before logout, across several re-checks');

    my $other = Test::Mojo->new(app());
    $other->ua->cookie_jar->ignore(sub { 1 });
    $other->post_ok('/api/auth/logout', { Cookie => $cookie })->status_is(200);

    $t->finished_ok(4401, 'closed with 4401 once the logout is seen');
};

subtest 'a password change elsewhere closes it too' => sub {
    my $t = login('alice', 'AlicePass12345');
    $t->websocket_ok('/api/logs/stream')->message_ok;

    admin_call(put => '/api/settings/users/alice', { password => 'AliceNewPass123' });
    $t->finished_ok(4401, 'closed after the admin reset');
    admin_call(put => '/api/settings/users/alice', { password => 'AlicePass12345' });
};

subtest 'an API-key socket has no session to re-check and stays open' => sub {
    my $t = Test::Mojo->new(app());
    $t->websocket_ok('/api/logs/stream' => { 'X-API-Key' => $KEY })->message_ok;
    run_loop_for(0.6);
    still_open($t, 'API key');
    $t->finish_ok;
};

done_testing();

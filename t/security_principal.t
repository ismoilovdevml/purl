#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use MIME::Base64 qw(encode_base64);

# ============================================
# REGRESSION (#91 security review, BLOCKER 1): an API key, bearer token or
# basic-auth credential plus a session cookie was authorised by the COOKIE.
#
# check_auth accepts key/bearer/basic before it looks at the session, so the
# cookie was never validated or ended, and handlers then read session('role'),
# session('username'): require_role, the AI gate, the audit actor, dashboard
# owner, the AI rate-limit key. An ingest key alone got 403 on
# GET /api/settings/users; the same key plus a revoked (or pre-#91 sid-less)
# admin cookie got 200, a re-signed cookie, and could create an admin.
#
# Now the credential that authenticated is the ONLY source of identity and
# role (Purl::Util::Principal). Precedence, stated: X-API-Key > Bearer (ingest
# routes only) > Basic > session cookie. When a key, bearer token or basic
# credential authenticates, a cookie sent alongside is ignored entirely: it
# adds no authority and is not renewed. Those callers have the role viewer,
# which is what they always had without a cookie.
# ============================================

use PurlTest::SessionApp qw(app storage login cookie_of forge_cookie admin_call csrf);
use Test::Mojo;
use Mojo::JSON ();
use Purl::Util::Principal qw(set_principal);

my $KEY = 'ingest-key-principal-test-0123456789';
$ENV{PURL_API_KEYS} = $KEY;

admin_call(post => '/api/settings/users',
    { username => 'bob', password => 'BobPass123456', role => 'viewer' });

# A revoked admin cookie (logged out), a live one and a pre-#91 one. The live
# one is minted AFTER the logout: logout revokes every session of the user.
my $revoked_admin = do {
    my $t = login('admin', 'StrongAdminPass123');
    my $ck = cookie_of($t);
    $t->post_ok('/api/auth/logout')->status_is(200);
    $ck;
};
my $live_admin = cookie_of(login('admin', 'StrongAdminPass123'));
my $legacy_admin = forge_cookie(username => 'admin', logged_in => 1,
                                auth_method => 'local', role => 'admin');

sub client {
    my $t = Test::Mojo->new(app());
    $t->ua->cookie_jar->ignore(sub { 1 });
    return $t;
}

sub basic { return 'Basic ' . encode_base64(join(':', @_), '') }

# No Set-Cookie for the session: the ignored cookie must not be renewed.
sub no_session_cookie {
    my ($t, $name) = @_;
    my @set = grep { $_->name eq 'mojolicious' } @{ $t->tx->res->cookies };
    ok !@set, "$name: the session cookie is not re-signed";
}

subtest 'control: the key alone is a viewer' => sub {
    client()->get_ok('/api/settings/users', { 'X-API-Key' => $KEY })->status_is(403);
};

for my $case (
    [ 'revoked admin cookie',   $revoked_admin ],
    [ 'pre-#91 sid-less admin', $legacy_admin ],
    [ 'LIVE admin cookie',      $live_admin ],
) {
    my ($name, $cookie) = @$case;

    subtest "X-API-Key + $name: key's role, not the cookie's" => sub {
        my $t = client();
        $t->get_ok('/api/settings/users', { 'X-API-Key' => $KEY, Cookie => $cookie })
          ->status_is(403, 'admin route refused');
        no_session_cookie($t, $name);

        $t->post_ok('/api/settings/users', { 'X-API-Key' => $KEY, Cookie => $cookie },
            json => { username => 'mallory', password => 'MalloryPass123', role => 'admin' })
          ->status_is(403, 'cannot create an admin');

        $t->get_ok('/api/audit', { 'X-API-Key' => $KEY, Cookie => $cookie })->status_is(403);
    };

    subtest "Basic (viewer bob) + $name: bob's principal, not the cookie's" => sub {
        my $t = client();
        $t->get_ok('/api/settings/users',
            { Authorization => basic('bob', 'BobPass123456'), Cookie => $cookie })
          ->status_is(403);
        no_session_cookie($t, $name);
    };
}

subtest 'Basic with the admin password + a live admin cookie: still only a viewer' => sub {
    client()->get_ok('/api/settings/users',
        { Authorization => basic('admin', 'StrongAdminPass123'), Cookie => $live_admin })
      ->status_is(403);
};

subtest 'mallory was never created' => sub {
    my $t = login('admin', 'StrongAdminPass123');
    $t->get_ok('/api/settings/users')->status_is(200);
    ok !grep({ $_->{username} eq 'mallory' } @{ $t->tx->res->json->{users} }), 'no mallory';
};

subtest 'Bearer on ingest + revoked admin cookie: ingest works, cookie untouched' => sub {
    my $t = client();
    $t->post_ok('/api/logs', { Authorization => "Bearer $KEY", Cookie => $revoked_admin },
        json => [ { level => 'INFO', service => 'x', message => 'hi' } ])
      ->status_isnt(401)->status_isnt(403);
    no_session_cookie($t, 'bearer');
};

subtest 'AI gate: a key plus a live admin cookie is not a signed-in user' => sub {
    client()->post_ok('/api/ai/query', { 'X-API-Key' => $KEY, Cookie => $live_admin },
        json => { question => 'errors?' })
      ->status_is(403)->json_like('/error' => qr/signed-in user/);
};

subtest 'the cookie alone still works as before' => sub {
    client()->get_ok('/api/settings/users', { Cookie => $live_admin })->status_is(200);
    client()->get_ok('/api/settings/users', { Cookie => $revoked_admin })->status_is(401);
};

# A header that did NOT authenticate used to waive CSRF by its mere presence.
subtest 'a bogus X-API-Key does not waive CSRF for a cookie-authorised write' => sub {
    my $t = client();
    $t->post_ok('/api/settings/users', { 'X-API-Key' => 'not-a-key', Cookie => $live_admin },
        json => { username => 'csrfvictim', password => 'CsrfVictim12345' })
      ->status_is(403)->json_is('/csrf' => Mojo::JSON::true);
};

subtest 'audit actor comes from the principal, not the cookie' => sub {
    my $c = app()->build_controller;
    $c->session(username => 'admin', logged_in => 1, role => 'admin');
    set_principal($c, via => 'api_key');
    my $n = @{ storage()->audit_events };
    $c->audit_event(action => 'probe');
    is storage()->audit_events->[$n]{actor}, 'system', 'key request: actor is not the cookie user';

    set_principal($c, via => 'session', username => 'alice', role => 'viewer');
    $c->audit_event(action => 'probe');
    is storage()->audit_events->[$n + 1]{actor}, 'alice', 'session request: its user';
};

subtest 'AI rate-limit key: per user only for a session principal' => sub {
    my $mw = Purl::API::Middleware::Auth->new;
    my $c  = app()->build_controller;
    $c->session(username => 'admin', logged_in => 1);
    set_principal($c, via => 'api_key');
    like $mw->_ai_rate_limit_key($c), qr/^ai:ip:/, 'key + cookie: keyed by IP, not the cookie user';
    set_principal($c, via => 'session', username => 'alice');
    is $mw->_ai_rate_limit_key($c), 'ai:user:alice', 'session: keyed by user';
};

done_testing();

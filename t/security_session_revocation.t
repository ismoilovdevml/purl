#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use POSIX ();
use Mojo::JSON qw(encode_json decode_json);

# ============================================
# REGRESSION (#91): logout did not revoke the session.
#
# Sessions are signed Mojolicious cookies. Logout only told the browser to
# delete its copy, so a cookie captured before logout kept authenticating —
# and every response re-signed it with a fresh 24h expiry, so a cookie in use
# never died. Password change and user deletion left sessions alive the same
# way.
#
# The fix (Purl::Util::Session) stamps every session with sid + iat and keeps a
# per-user auth.sessions_valid_after in settings.json, which every worker and
# replica re-reads. Everything below drives the REAL app over Test::Mojo; the
# cross-process subtests fork, because a per-process fix is the defect class
# this code base keeps meeting (#18/#37/#64).
# ============================================

use PurlTest::SessionApp qw(
    config_dir build_app app csrf login cookie_of replay forge_cookie admin_call
    in_child
);
use Test::Mojo;
use Purl::Config;
use Purl::API::Controller::Auth;
use Purl::Util::Session;

my $DIR = config_dir();
my $app = app();

admin_call(post => '/api/settings/users',
    { username => 'alice', password => 'AlicePass12345', role => 'admin' });
admin_call(post => '/api/settings/users',
    { username => 'bob', password => 'BobPass123456', role => 'viewer' });

# ============================================

subtest 'a cookie captured before logout is dead after it' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);
    ok $cookie, 'captured the session cookie';

    my ($me, $st) = replay($cookie);
    is $me, 1,   'before logout: replay authenticates';
    is $st, 200, 'before logout: protected route 200';

    $t->post_ok('/api/auth/logout')->status_is(200);

    ($me, $st) = replay($cookie);
    is $me, 0,   'after logout: /api/auth/me authenticated 0';
    is $st, 401, 'after logout: /api/alerts 401';

    # The response to the rejected replay must not hand the session back.
    my $r = Test::Mojo->new($app);
    $r->ua->cookie_jar->ignore(sub { 1 });
    $r->get_ok('/api/auth/me', { Cookie => $cookie });
    my ($set) = grep { $_->name eq 'mojolicious' } @{ $r->tx->res->cookies };
    ok !$set || $set->expires && $set->expires < time,
        'a rejected cookie is expired, not re-signed with a fresh lifetime';

    login('alice', 'AlicePass12345');
    ($me) = replay(cookie_of(login('alice', 'AlicePass12345')));
    is $me, 1, 'logging in again right after logout works';
};

subtest 'an in-flight request re-setting the cookie after logout does not resurrect it' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);

    # A request that was already authenticated when logout landed finishes
    # later and its Set-Cookie puts a re-signed session back in the browser.
    my $inflight = Test::Mojo->new($app);
    $inflight->ua->cookie_jar->ignore(sub { 1 });
    $inflight->get_ok('/api/auth/me', { Cookie => $cookie })->json_is('/authenticated' => 1);
    my ($resigned) = grep { $_->name eq 'mojolicious' } @{ $inflight->tx->res->cookies };
    ok $resigned, 'the in-flight response carried a re-signed cookie';

    $t->post_ok('/api/auth/logout')->status_is(200);

    my ($me, $st) = replay('mojolicious=' . $resigned->value);
    is $me, 0,   'the re-signed cookie is not authenticated';
    is $st, 401, 'and is refused on a protected route';
};

# ---- across processes ------------------------------------------------------

# Run $steps in a forked child and return what each step reported. The child
# either keeps the parent's app (a prefork worker: forked after startup, warm
# config snapshot) or builds its own from scratch (another replica sharing the
# config dir). Between steps it waits for the parent, so the parent can act
# (log out) while the child is alive and warm.
sub in_other_process {
    my ($mode, $cookie, $n_steps, $between) = @_;

    pipe(my $from_child, my $to_parent) or die $!;
    pipe(my $from_parent, my $to_child) or die $!;
    my $pid = fork() // die "fork: $!";

    if (!$pid) {
        close $from_child; close $to_child;
        my $ok = eval {
            my $other = $mode eq 'replica' ? build_app() : $app;
            for my $i (1 .. $n_steps) {
                if ($i > 1) { my $go = <$from_parent> }
                my ($me, $st) = replay($cookie, $other);
                syswrite $to_parent, encode_json([ $$, $me, $st ]) . "\n";
            }
            1;
        };
        syswrite $to_parent, encode_json([ 'error', "$@" ]) . "\n" unless $ok;
        POSIX::_exit(0);    # no END blocks: the parent owns the temp dir
    }

    close $to_parent; close $from_parent;
    $to_child->autoflush(1);
    my @results;
    for my $i (1 .. $n_steps) {
        if ($i > 1) { $between->($i); print {$to_child} "go\n" }
        my $line = <$from_child>;
        push @results, $line ? decode_json($line) : [ 'error', 'child died' ];
    }
    waitpid $pid, 0;
    return @results;
}

for my $mode (qw(prefork replica)) {
    subtest "logout in this process is honoured by another ($mode)" => sub {
        my $t = login('alice', 'AlicePass12345');
        my $cookie = cookie_of($t);

        my ($before, $after) = in_other_process($mode, $cookie, 2, sub {
            $t->post_ok('/api/auth/logout')->status_is(200);
        });

        isnt $before->[0], $$, 'the replay really ran in another process';
        is_deeply [ @$before[1, 2] ], [ 1, 200 ],
            'other process accepts the cookie before logout';
        is_deeply [ @$after[1, 2] ], [ 0, 401 ],
            'other process rejects it after logout here';
    };
}

subtest 'logout on another replica kills the cookie here' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);
    is +(replay($cookie))[0], 1, 'valid here to begin with (this config is warm)';

    # A replica built from scratch in its own process handles the logout.
    my $code = in_child(sub {
        return { code => Test::Mojo->new(build_app())
              ->post_ok('/api/auth/logout', { Cookie => $cookie })->tx->res->code };
    })->{code};
    is $code, 200, 'the other replica logged the session out';

    is_deeply [ replay($cookie) ], [ 0, 401 ], 'rejected here, where the logout did not run';
};

# ---- password change, user delete/update -----------------------------------

subtest 'password change kills every other session of that user' => sub {
    my $mine  = login('bob', 'BobPass123456');
    my $other = cookie_of(login('bob', 'BobPass123456'));
    my $old_mine = cookie_of($mine);

    $mine->post_ok('/api/auth/change-password', { 'X-CSRF-Token' => csrf($mine) },
        json => { current_password => 'BobPass123456', new_password => 'BobNewPass7890' })
      ->status_is(200);

    $mine->get_ok('/api/auth/me')->json_is('/authenticated' => 1,
        'the session that changed the password stays signed in');
    is_deeply [ replay($other) ],    [ 0, 401 ], 'another session is killed';
    is_deeply [ replay($old_mine) ], [ 0, 401 ], 'a copy of the pre-change cookie is killed';

    login('bob', 'BobNewPass7890');
};

subtest 'a deleted user loses their sessions' => sub {
    admin_call(post => '/api/settings/users',
        { username => 'carol', password => 'CarolPass12345', role => 'admin' });
    my $cookie = cookie_of(login('carol', 'CarolPass12345'));
    is_deeply [ replay($cookie) ], [ 1, 200 ], 'carol is signed in';

    admin_call(delete => '/api/settings/users/carol');
    is_deeply [ replay($cookie) ], [ 0, 401 ], 'deleted user: session rejected';

    # Re-creating the name must not revive a cookie of the deleted account.
    admin_call(post => '/api/settings/users',
        { username => 'carol', password => 'CarolPass99999', role => 'viewer' });
    is_deeply [ replay($cookie) ], [ 0, 401 ], 'same-name account does not revive it';
    admin_call(delete => '/api/settings/users/carol');
};

subtest 'a role change by an admin kills the old sessions' => sub {
    admin_call(post => '/api/settings/users',
        { username => 'dave', password => 'DavePass123456', role => 'admin' });
    my $cookie = cookie_of(login('dave', 'DavePass123456'));

    admin_call(put => '/api/settings/users/dave', { role => 'viewer' });
    is_deeply [ replay($cookie) ], [ 0, 401 ],
        'a demoted admin cannot keep a session that says role=admin';
    admin_call(delete => '/api/settings/users/dave');
};

# ---- cookie shape and lifetime ---------------------------------------------

subtest 'a cookie from before this fix (no sid/iat) is rejected' => sub {
    my $legacy = forge_cookie(username => 'alice', logged_in => 1,
                              auth_method => 'local', role => 'admin');
    is_deeply [ replay($legacy) ], [ 0, 401 ], 'no sid/iat => signed out';

    my $no_sid = forge_cookie(username => 'alice', logged_in => 1,
                              auth_method => 'local', role => 'admin', iat => time);
    is_deeply [ replay($no_sid) ], [ 0, 401 ], 'iat without sid => signed out';

    my $well_formed = forge_cookie(username => 'alice', logged_in => 1,
        auth_method => 'local', role => 'admin', sid => 'f' x 32, iat => time + 1);
    is_deeply [ replay($well_formed) ], [ 1, 200 ],
        'control: the same session with sid/iat is accepted';
};

subtest 'absolute max age: sliding renewal cannot extend a session' => sub {
    local $ENV{PURL_SESSION_MAX_AGE} = 3600;

    my $t = login('alice', 'AlicePass12345');
    $t->get_ok('/api/auth/me')->json_is('/authenticated' => 1) for 1 .. 3;
    my $renewed = cookie_of($t);

    my $real = \&Purl::Util::Session::_now;
    no warnings 'redefine';
    local *Purl::Util::Session::_now = sub { $real->() + 3601 };

    # Mojolicious' own 24h sliding expiry is still fine at +1h; only the
    # absolute lifetime can refuse this cookie.
    is_deeply [ replay($renewed) ], [ 0, 401 ], 'older than max_age => rejected';

    my $fresh = forge_cookie(username => 'alice', logged_in => 1, auth_method => 'local',
        role => 'admin', sid => 'e' x 32, iat => $real->() + 3000);
    is_deeply [ replay($fresh) ], [ 1, 200 ], 'control: a younger session is still accepted';
};

subtest 'max age: ENV, then session.max_age, then 7 days' => sub {
    my $cfg = Purl::Config->new(config_file => "$DIR/settings.json");
    local $ENV{PURL_SESSION_MAX_AGE};
    is Purl::Util::Session::session_max_age($cfg), 7 * 86400, 'default 7 days';
    $cfg->set('session', 'max_age', 1800);
    is Purl::Util::Session::session_max_age($cfg), 1800, 'session.max_age from settings';
    $ENV{PURL_SESSION_MAX_AGE} = 900;
    is Purl::Util::Session::session_max_age($cfg), 900, 'PURL_SESSION_MAX_AGE wins';
    $ENV{PURL_SESSION_MAX_AGE} = 'forever';
    is Purl::Util::Session::session_max_age($cfg), 1800, 'garbage ENV ignored, never unlimited';
    $cfg->update_section('session', sub { delete $_[0]{max_age} });
};

# ---- LDAP and SSO logins issue revocable sessions --------------------------

{
    package FakeLDAP;
    sub new          { bless {}, shift }
    sub config       { { admin_group => 'admins' } }
    sub authenticate { { success => 1, groups => ['admins'] } }

    package FakeSAML;
    sub new               { bless {}, shift }
    sub config            { { admin_group => 'admins' } }
    sub validate_response { { success => 1, username => 'sso-user@corp', groups => [] } }
}

# Run a controller action on a real Mojolicious controller and return the
# resulting signed cookie.
sub external_login {
    my ($action, %mw) = @_;
    my $ctrl = Purl::API::Controller::Auth->new(
        storage  => PurlTest::SessionApp::storage(),
        settings => Purl::Config->new(config_file => "$DIR/settings.json"), %mw);
    my $c = $app->build_controller;
    if ($action eq 'login') {
        $c->req->method('POST');
        $c->req->body(encode_json({ username => 'ldap-user', password => 'whatever' }));
    } else {
        $c->req->url->query(SAMLResponse => 'x', RelayState => '/');
    }
    $ctrl->$action($c);
    my %session = %{ $c->session };
    $app->sessions->store($c);
    my ($ck) = grep { $_->name eq 'mojolicious' } @{ $c->res->cookies };
    return (\%session, $ck->name . '=' . $ck->value);
}

for my $case (
    [ LDAP => login        => ldap_middleware => FakeLDAP->new, 'ldap' ],
    [ SSO  => sso_callback => saml_middleware => FakeSAML->new, 'saml' ],
) {
    my ($label, $action, $mw_key, $mw, $method) = @$case;
    subtest "$label login issues sid + iat and its logout revokes" => sub {
        my ($session, $cookie) = external_login($action, $mw_key => $mw);
        like $session->{sid}, qr/\A[0-9a-f]{32}\z/, 'sid is 128 random bits (hex)';
        cmp_ok abs($session->{iat} - time), '<', 5, 'iat is now';
        is $session->{auth_method}, $method, "auth_method $method";

        my $t = Test::Mojo->new($app);
        $t->ua->cookie_jar->ignore(sub { 1 });
        $t->get_ok('/api/auth/me', { Cookie => $cookie })
          ->json_is('/authenticated' => 1)->json_is('/auth_method' => $method);

        $t->post_ok('/api/auth/logout', { Cookie => $cookie })->status_is(200);
        is_deeply [ replay($cookie) ], [ 0, 401 ],
            "$label user (no local account) is revoked by logout too";
    };
}

subtest 'a cookie from a replica whose clock runs ahead still dies at logout' => sub {
    login('alice', 'AlicePass12345');    # alice exists and has a stamp by now
    my $ahead = forge_cookie(username => 'alice', logged_in => 1, auth_method => 'local',
        role => 'admin', sid => 'd' x 32, iat => time + 30);
    is_deeply [ replay($ahead) ], [ 1, 200 ], 'accepted while live';

    Test::Mojo->new($app)->post_ok('/api/auth/logout', { Cookie => $ahead })->status_is(200);
    is_deeply [ replay($ahead) ], [ 0, 401 ],
        'its own logout revokes it although its iat is later than this clock';
};

subtest 'logout with a dead cookie cannot revoke someone else' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $forged = forge_cookie(username => 'alice', logged_in => 1);   # no sid/iat
    Test::Mojo->new($app)->post_ok('/api/auth/logout', { Cookie => $forged })->status_is(200);
    $t->get_ok('/api/auth/me')->json_is('/authenticated' => 1,
        'alice is still signed in: only a valid session can trigger revocation');
};

done_testing();

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use MIME::Base64 qw(encode_base64);

# ============================================
# REGRESSION (#91 security re-review of db72a24).
#
#   MAJOR 1  change_password verified the current password against a snapshot,
#            hashed (slow), then wrote unconditionally. An admin reset landing
#            during the hash was undone and the caller left with a fresh
#            session on the password the admin had just taken away.
#   NIT      POST /api/auth/logout accepted a live session without a CSRF token.
#   NIT      Basic auth for a user named "0" failed (truth test, not defined).
#   NIT      Basic admin:admin was not held to the forced password change.
# ============================================

use PurlTest::SessionApp qw(
    config_dir app csrf login cookie_of replay admin_call in_child with_csrf
);
use Test::Mojo;
use Mojo::JSON ();
use Purl::Config;
use Purl::API::Middleware::Auth;
use Purl::Util::Session qw(mark_revoked revoke_sessions);

admin_call(post => '/api/settings/users',
    { username => 'alice', password => 'AlicePass12345', role => 'viewer' });

sub replica { return Purl::Config->new(config_file => config_dir() . '/settings.json') }

sub basic { my ($u, $p) = @_; return { Authorization => 'Basic ' . encode_base64("$u:$p", '') } }

# ---- MAJOR 1: change_password never undoes a concurrent reset --------------

# Run $during on ANOTHER replica (a forked process with its own Purl::Config)
# in the middle of the change_password bcrypt hash.
{
    my $hook;
    my $orig = \&Purl::API::Middleware::Auth::hash_password;
    no warnings 'redefine';
    *Purl::API::Middleware::Auth::hash_password = sub {
        my $h = $orig->(@_);
        if (my $run = $hook) { undef $hook; $run->() }
        return $h;
    };

    sub change_password_while {
        my ($during, $new_password) = @_;
        my $t = login('alice', 'AlicePass12345');
        my $cookie = cookie_of($t);
        my $child;
        $hook = sub { $child = in_child($during) };
        $t->post_ok('/api/auth/change-password', { 'X-CSRF-Token' => csrf($t) },
            json => { current_password => 'AlicePass12345', new_password => $new_password });
        is $child->{saved}, 1, 'the other replica wrote mid-hash' or diag explain $child;
        return ($t, $cookie);
    }
}

subtest 'PoC: an admin reset during the hash is not undone' => sub {
    my ($t, $cookie) = change_password_while(sub {
        my $cfg  = replica();
        my $hash = Purl::API::Middleware::Auth->new->hash_password('AliceReset12345');
        my $ok = $cfg->update_section('auth', sub {
            my ($section) = @_;
            $section->{users}{alice} = { password => $hash, role => 'viewer' };
            mark_revoked($section, 'alice');
        });
        return { saved => $ok ? 1 : 0 };
    }, 'AttackerPass12345');

    $t->status_is(409)->json_like('/error' => qr/changed elsewhere/);
    is_deeply [ replay($cookie) ], [ 0, 401 ], 'the caller holds no valid session';

    Test::Mojo->new(app())->post_ok('/api/auth/login',
        json => { username => 'alice', password => 'AttackerPass12345' })->status_is(401);
    login('alice', 'AliceReset12345');    # the admin's password is the one in force

    admin_call(put => '/api/settings/users/alice', { password => 'AlicePass12345' });
};

subtest 'a revocation alone during the hash also refuses the change' => sub {
    my ($t, $cookie) = change_password_while(sub {
        return { saved => revoke_sessions(replica(), 'alice') ? 1 : 0 };
    }, 'AliceOther12345');

    $t->status_is(409)->json_like('/error' => qr/session was revoked/);
    login('alice', 'AlicePass12345');    # nothing was changed
    is_deeply [ replay($cookie) ], [ 0, 401 ], 'and no fresh session was issued';
};

subtest 'control: an undisturbed change still works' => sub {
    my $t = login('alice', 'AlicePass12345');
    $t->post_ok('/api/auth/change-password', { 'X-CSRF-Token' => csrf($t) },
        json => { current_password => 'AlicePass12345', new_password => 'AliceOther12345' })
      ->status_is(200);
    login('alice', 'AliceOther12345');
    admin_call(put => '/api/settings/users/alice', { password => 'AlicePass12345' });
};

# ---- NIT: logout of a live session needs the CSRF token --------------------

subtest 'logout: CSRF required for a live session, not for a dead cookie' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);

    $t->post_ok('/api/auth/logout')->status_is(403)->json_is('/csrf' => Mojo::JSON::true);
    is_deeply [ replay($cookie) ], [ 1, 200 ], 'a cross-site POST did not sign her out';

    $t->post_ok('/api/auth/logout', with_csrf())->status_is(200);
    is_deeply [ replay($cookie) ], [ 0, 401 ], 'with the token it did';

    my $dead = Test::Mojo->new(app());
    $dead->ua->cookie_jar->ignore(sub { 1 });
    $dead->post_ok('/api/auth/logout', { Cookie => $cookie })->status_is(200,
        'a dead cookie is dropped without a token: nothing to protect');
};

# ---- NITs: Basic auth ------------------------------------------------------

sub set_user {
    my ($name, $entry) = @_;
    my $prev;
    replica()->update_section('auth', sub {
        my ($section) = @_;
        $prev = $section->{users}{$name};
        if (defined $entry) { $section->{users}{$name} = $entry }
        else                { delete $section->{users}{$name} }
    });
    return $prev;
}

subtest 'Basic auth works for a user named "0"' => sub {
    set_user('0', { password => Purl::API::Middleware::Auth->new->hash_password('ZeroPass12345'),
                    role => 'viewer' });
    Test::Mojo->new(app())->get_ok('/api/alerts', basic('0', 'ZeroPass12345'))->status_is(200);
    Test::Mojo->new(app())->get_ok('/api/alerts', basic('0', 'wrong-password'))->status_is(401);
    set_user('0', undef);
};

subtest 'Basic admin:admin is held to the forced password change' => sub {
    my $prev = set_user('admin', { password => 'admin', role => 'admin' });    # legacy plaintext
    Test::Mojo->new(app())->get_ok('/api/alerts', basic('admin', 'admin'))
      ->status_is(403)->json_is('/password_change_required' => Mojo::JSON::true);
    Test::Mojo->new(app())->get_ok('/api/auth/me', basic('admin', 'admin'))->status_is(200);
    set_user('admin', $prev);

    # control: any other Basic user is not gated
    Test::Mojo->new(app())->get_ok('/api/alerts', basic('alice', 'AlicePass12345'))->status_is(200);
};

done_testing();

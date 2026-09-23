#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

# ============================================
# REGRESSION (#91 security review, MAJOR 2 / MAJOR 3 / MINOR 4 / NIT 6):
# revocation stamps must never be lost, overwritten backwards, or silently
# fail to persist.
#
#   MAJOR 2  revoke_sessions overwrote the stamp: a clock-ahead cookie that
#            logged out (stamp = its iat, now+30) came back to life when an
#            admin reset the password a moment later (stamp = now).
#   MAJOR 3  Settings/Users edited settings->_config in place and save()d
#            without the lock, with a bcrypt hash in between — a logout that
#            another replica wrote meanwhile was overwritten by the stale
#            snapshot and the logged-out cookie came back.
#   MINOR 4  logout / change_password ignored the save result and said "ok".
#   NIT 6    PURL_SESSION_MAX_AGE=inf passed looks_like_number => unlimited.
# ============================================

use PurlTest::SessionApp qw(
    config_dir storage build_app app csrf login cookie_of replay forge_cookie
    admin_call in_child
);
use Test::Mojo;
use Purl::Config;
use Purl::Util::Session qw(mark_revoked revoke_sessions session_max_age);

admin_call(post => '/api/settings/users',
    { username => 'alice', password => 'AlicePass12345', role => 'viewer' });

sub stamp_of {
    my ($user) = @_;
    my $cfg = Purl::Config->new(config_file => config_dir() . '/settings.json');
    return $cfg->get_section('auth')->{sessions_valid_after}{$user};
}

# ---- MAJOR 2: the stamp only moves forward --------------------------------

subtest 'mark_revoked never moves a stamp backwards, always strictly forward' => sub {
    my $ahead = time + 30;
    my %section = (sessions_valid_after => { alice => $ahead });
    my $floor_born = $ahead + 0.001;    # what start_session issues meanwhile
    mark_revoked(\%section, 'alice');
    my $new = $section{sessions_valid_after}{alice};
    cmp_ok $new, '>', $ahead, 'a later existing stamp is not rewound to now';
    cmp_ok $new, '>=', $floor_born, 'and moves past sessions issued at stamp + 1ms';

    mark_revoked(\%section, 'alice', $ahead + 5);
    is $section{sessions_valid_after}{alice}, $ahead + 5, '$at_least wins when it is later';

    my %fresh;
    mark_revoked(\%fresh, 'bob');
    cmp_ok abs($fresh{sessions_valid_after}{bob} - time), '<', 5, 'no stamp yet: now';
};

subtest 'PoC: a logged-out clock-ahead cookie stays dead after an admin password reset' => sub {
    login('alice', 'AlicePass12345');
    my $ahead = forge_cookie(username => 'alice', logged_in => 1, auth_method => 'local',
        role => 'viewer', sid => 'c' x 32, iat => time + 30);
    is_deeply [ replay($ahead) ], [ 1, 200 ], 'accepted while live';

    Test::Mojo->new(app())->post_ok('/api/auth/logout', { Cookie => $ahead })->status_is(200);
    is_deeply [ replay($ahead) ], [ 0, 401 ], 'dead after its logout';

    # While the stamp is ahead of this clock, a fresh login is issued just past
    # it; the admin reset must kill that one too, not leave the stamp in place.
    my $fresh = cookie_of(login('alice', 'AlicePass12345'));
    is_deeply [ replay($fresh) ], [ 1, 200 ], 'a login after it works';

    admin_call(put => '/api/settings/users/alice', { password => 'AliceReset12345' });
    is_deeply [ replay($ahead) ], [ 0, 401 ],
        'still dead after the reset: the reset did not rewind the stamp to "now"';
    is_deeply [ replay($fresh) ], [ 0, 401 ],
        'the post-logout login is killed by the reset too';
    admin_call(put => '/api/settings/users/alice', { password => 'AlicePass12345' });
};

# ---- MAJOR 3: user writes never drop a concurrent revocation ---------------

# Run $write while, in the middle of its bcrypt hash, ANOTHER replica logs
# alice out. The other replica is a forked process with its own Purl::Config
# making exactly the write a logout makes there (revoke_sessions); it cannot
# speak HTTP because it is forked inside this process's running IOLoop.
# Then alice's cookie must be dead.
{
    my $hook;
    my $orig = \&Purl::API::Middleware::Auth::hash_password;
    no warnings 'redefine';
    *Purl::API::Middleware::Auth::hash_password = sub {
        my $h = $orig->(@_);
        if (my $run = $hook) { undef $hook; $run->() }
        return $h;
    };

    sub logout_during_hash {
        my ($write) = @_;
        my $alice = cookie_of(login('alice', 'AlicePass12345'));
        my $admin = login('admin', 'StrongAdminPass123');
        my $token = csrf($admin);

        my $child;
        $hook = sub {
            $child = in_child(sub {
                my $replica = Purl::Config->new(config_file => config_dir() . '/settings.json');
                return { saved => revoke_sessions($replica, 'alice') ? 1 : 0 };
            });
        };
        $write->($admin, $token);
        is $child->{saved}, 1, 'the other replica revoked alice mid-hash';
        return $alice;
    }
}

subtest 'create_user during a logout on another replica keeps the revocation' => sub {
    my $alice = logout_during_hash(sub {
        my ($t, $token) = @_;
        $t->post_ok('/api/settings/users', { 'X-CSRF-Token' => $token },
            json => { username => 'carol', password => 'CarolPass12345' })->status_is(200);
    });
    is_deeply [ replay($alice) ], [ 0, 401 ], 'alice stays logged out';
    ok defined stamp_of('alice'), 'her stamp is in settings.json';
    login('carol', 'CarolPass12345');    # and the create itself was saved
};

subtest 'update_user during a logout on another replica keeps the revocation' => sub {
    my $alice = logout_during_hash(sub {
        my ($t, $token) = @_;
        $t->put_ok('/api/settings/users/carol', { 'X-CSRF-Token' => $token },
            json => { password => 'CarolNewPass123' })->status_is(200);
    });
    is_deeply [ replay($alice) ], [ 0, 401 ], 'alice stays logged out';
    login('carol', 'CarolNewPass123');
};

subtest 'create/update/delete refusals still answer as before' => sub {
    admin_call(post => '/api/settings/users',
        { username => 'carol', password => 'CarolPass12345' }, 409);
    admin_call(put => '/api/settings/users/nobody', { role => 'admin' }, 404);
    admin_call(delete => '/api/settings/users/nobody', undef, 404);
    admin_call(delete => '/api/settings/users/admin', undef, 400);    # yourself
    admin_call(delete => '/api/settings/users/carol');
};

# ---- MINOR 4: a revocation that was not persisted is not reported as done --

subtest 'logout: revocation not persisted => 500, audited, cookie still dropped' => sub {
    my $t = login('alice', 'AlicePass12345');
    my $cookie = cookie_of($t);
    my $n = @{ storage()->audit_events };
    {
        no warnings 'redefine';
        local *Purl::Config::save = sub { $_[0]{_last_save_error} = 'disk full'; return 0 };
        $t->post_ok('/api/auth/logout')->status_is(500)
          ->json_like('/error' => qr/could not be revoked/);
    }
    my ($set) = grep { $_->name eq 'mojolicious' } @{ $t->tx->res->cookies };
    ok $set && $set->expires && $set->expires < time, 'the browser is still told to drop it';
    my ($ev) = grep { $_->{action} eq 'logout' } @{ storage()->audit_events }[$n .. $#{ storage()->audit_events }];
    is $ev->{status}, 'failure', 'audited as a failure';
    is $ev->{actor},  'alice',   'with the user it concerns';

    # Honest about the consequence: the copied cookie is still valid.
    is +(replay($cookie))[0], 1, 'the unrevoked copy still works (why this is a 500)';
    Test::Mojo->new(app())->post_ok('/api/auth/logout', { Cookie => $cookie })->status_is(200);
};

subtest 'change_password: not persisted => 500, nothing claimed' => sub {
    my $t = login('alice', 'AlicePass12345');
    {
        no warnings 'redefine';
        local *Purl::Config::save = sub { $_[0]{_last_save_error} = 'disk full'; return 0 };
        $t->post_ok('/api/auth/change-password', { 'X-CSRF-Token' => csrf($t) },
            json => { current_password => 'AlicePass12345', new_password => 'AliceOther12345' })
          ->status_is(500);
    }
    login('alice', 'AlicePass12345');    # the old password still works: nothing changed
};

# ---- NIT 6: max age can never become unlimited -----------------------------

subtest 'non-finite max age is ignored' => sub {
    for my $v (qw(inf Inf -inf nan NaN 1e400 infinity)) {
        local $ENV{PURL_SESSION_MAX_AGE} = $v;
        is session_max_age(undef), 7 * 86400, "PURL_SESSION_MAX_AGE=$v => default";
    }
    local $ENV{PURL_SESSION_MAX_AGE} = 3600;
    is session_max_age(undef), 3600, 'control: a finite value is used';
};

done_testing();

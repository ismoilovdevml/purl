#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json);

use Purl::Config;
use Purl::API::Middleware::Auth;
use Purl::API::Controller::Auth;
use Purl::API::Controller::Settings;

# ============================================
# GitHub issue #18 — a newly created user cannot log in.
#
# Everything here is REAL except the Mojolicious controller context: real
# bcrypt hashing, the real Settings controller that creates the user, the real
# Auth controller that verifies the login, and a real Purl::Config over a real
# settings.json on disk.
#
# ROOT CAUSE (see the "prefork" subtest): the server runs
# Mojo::Server::Prefork. setup_routes() builds ONE Purl::Config in the manager
# process and every worker inherits a private COPY of its parsed settings
# through fork(). create_user mutates the copy belonging to whichever worker
# served the POST and writes settings.json; the other three workers keep the
# pre-fork snapshot for the rest of their lives. The subsequent login is
# load-balanced across all four workers, so it usually lands on one that has
# never heard of the user and answers 401. Nothing about the password hash,
# the role, or must_change_password was ever wrong — the record simply was not
# there.
# ============================================

# ---- controller context stand-in ------------------------------------------
{
    package MockLog;
    sub new { bless {}, shift }
    sub error { } sub warn { } sub info { } sub debug { }

    package MockApp;
    sub new { bless { log => MockLog->new }, shift }
    sub log { $_[0]{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, shift }
    sub header { my $s = shift; my $k = shift; $s->{h}{$k} = shift if @_; $s->{h}{$k} }
    sub content_type { my $s = shift; $s->{h}{ct} = shift if @_; $s->{h}{ct} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, shift }
    sub headers { $_[0]{headers} }

    package MockReq;
    sub new { bless { body => $_[1] // '' }, $_[0] }
    sub body { $_[0]{body} }

    package MockCtx;
    sub new {
        my ($class, %o) = @_;
        return bless {
            req      => MockReq->new($o{body}),
            res      => MockRes->new,
            rendered => undef,
            stash    => $o{stash}   // {},
            session  => $o{session} // {},
            params   => $o{params}  // {},
            app      => MockApp->new,
        }, $class;
    }
    sub req { $_[0]{req} }
    sub res { $_[0]{res} }
    sub app { $_[0]{app} }
    sub param { $_[0]{params}{ $_[1] } }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]{rendered} }
    sub redirect_to { }
    sub audit_event { }
    sub stash {
        my ($s, $k, $v) = @_;
        return $s->{stash} unless defined $k;
        $s->{stash}{$k} = $v if defined $v;
        return $s->{stash}{$k};
    }
    sub session {
        my ($s, @a) = @_;
        return $s->{session} unless @a;
        return $s->{session}{ $a[0] } if @a == 1;
        $s->{session}{ $a[0] } = $a[1];
        return;
    }
}

# ---- harness ---------------------------------------------------------------

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

# Seed with an existing admin so delete_user never trips the "last user" guard.
open my $seed, '>', $file or die $!;
print {$seed} '{"auth":{"users":{"root":{"password":"x","role":"admin"}}}}';
close $seed;

my $auth_mw = Purl::API::Middleware::Auth->new(config => {});

sub settings_ctrl {
    my ($settings) = @_;
    return Purl::API::Controller::Settings->new(
        settings        => $settings,
        auth_middleware => $auth_mw,
        storage         => undef,
    );
}

sub auth_ctrl {
    my ($settings) = @_;
    return Purl::API::Controller::Auth->new(
        settings        => $settings,
        auth_middleware => $auth_mw,
        storage         => undef,
    );
}

# Returns the rendered response hash.
sub create_user {
    my ($settings, $username, $password, %opts) = @_;
    my $c = MockCtx->new(
        body    => encode_json({ username => $username, password => $password,
                                 role => $opts{role} // 'viewer' }),
        session => { role => 'admin' },
        stash   => $opts{stash} // {},
    );
    settings_ctrl($settings)->create_user($c);
    return $c->rendered;
}

sub delete_user {
    my ($settings, $username) = @_;
    my $c = MockCtx->new(
        params  => { username => $username },
        session => { role => 'admin' },
    );
    settings_ctrl($settings)->delete_user($c);
    return $c->rendered;
}

sub login {
    my ($settings, $username, $password) = @_;
    # Each login gets a fresh username so the brute-force lockout counter from
    # a deliberately-failing attempt cannot bleed into the next subtest.
    my $c = MockCtx->new(body => encode_json({ username => $username, password => $password }));
    auth_ctrl($settings)->login($c);
    return $c->rendered;
}

# ============================================
# No plan-driven user cap
# ============================================

subtest 'user creation is not capped by a user count' => sub {
    my $s = Purl::Config->new(config_file => $file);
    my @names = map { "bulk_user_$_" } 1 .. 12;
    for my $name (@names) {
        my $r = create_user($s, $name, 'password123');
        is $r->{json}{status}, 'ok', "$name created";
    }
    delete_user($s, $_) for @names;
};

# ============================================
# Same process: create -> login -> delete -> login
# ============================================

subtest 'create, log in, delete, refused — same Purl::Config' => sub {
    my $s = Purl::Config->new(config_file => $file);

    my $created = create_user($s, 'alice', 'alicepassword');
    is $created->{json}{status}, 'ok', 'user created';

    my $ok = login($s, 'alice', 'alicepassword');
    is $ok->{json}{authenticated}, 1, 'created user can log in';
    is $ok->{json}{username}, 'alice', 'session is for the right user';
    is $ok->{json}{role}, 'viewer', 'role from the stored record';

    my $bad = login($s, 'alice', 'wrongpassword');
    is $bad->{status}, 401, 'wrong password still refused';

    my $deleted = delete_user($s, 'alice');
    is $deleted->{json}{status}, 'ok', 'user deleted';

    my $after = login($s, 'alice', 'alicepassword');
    is $after->{status}, 401, 'deleted user can no longer log in';
};

# ============================================
# THE REGRESSION: prefork — the worker that writes is not the worker
# that authenticates.
# ============================================

subtest 'create on one worker, log in on another' => sub {
    # Two Purl::Config instances over one settings.json: exactly what fork()
    # leaves behind. $writer serves POST /api/settings/users, $reader serves
    # POST /api/auth/login.
    my $writer = Purl::Config->new(config_file => $file);
    my $reader = Purl::Config->new(config_file => $file);

    # $reader has already answered a request, so its snapshot is warm and
    # predates the create — the exact situation that produced the 401.
    ok !exists $reader->get_section('auth')->{users}{bob},
        'reader has no bob before creation';

    my $created = create_user($writer, 'bob', 'bobpassword1');
    is $created->{json}{status}, 'ok', 'writer created the user';

    my $ok = login($reader, 'bob', 'bobpassword1');
    is $ok->{json}{authenticated}, 1,
        'a worker that never saw the create still authenticates the new user';
    is $ok->{json}{role}, 'viewer', 'role survives the cross-worker read';

    # And the delete has to propagate the same way, or a removed account keeps
    # working on three workers out of four.
    my $deleted = delete_user($writer, 'bob');
    is $deleted->{json}{status}, 'ok', 'writer deleted the user';

    my $after = login($reader, 'bob', 'bobpassword1');
    is $after->{status}, 401, 'deleted user is refused on the other worker too';
};

subtest 'a third worker created before any write also sees the user' => sub {
    my $writer = Purl::Config->new(config_file => $file);
    my $reader = Purl::Config->new(config_file => $file);
    my $other  = Purl::Config->new(config_file => $file);

    create_user($writer, 'carol', 'carolpassword');

    for my $w ([ reader => $reader ], [ other => $other ]) {
        my ($name, $cfg) = @$w;
        my $r = login($cfg, 'carol', 'carolpassword');
        is $r->{json}{authenticated}, 1, "worker '$name' authenticates carol";
    }

    delete_user($writer, 'carol');
};

# ============================================
# The stored record itself
# ============================================

subtest 'stored password is a bcrypt hash the login path recognises' => sub {
    my $s = Purl::Config->new(config_file => $file);
    create_user($s, 'dave', 'davepassword');

    my $entry = $s->get_section('auth')->{users}{dave};
    is ref $entry, 'HASH', 'stored as a hash with password + role';
    like $entry->{password}, qr/^\$2[aby]\$\d{2}\$.{53}$/,
        'bcrypt format, exactly what Auth.pm dispatches on';
    isnt $entry->{password}, 'davepassword', 'never stored in the clear';

    my ($valid) = $auth_mw->verify_password('davepassword', $entry->{password});
    ok $valid, 'the middleware verifies its own hash';

    my $r = login($s, 'dave', 'davepassword');
    ok !exists $r->{json}{must_change_password},
        'a normal new user is not forced into a password change';

    delete_user($s, 'dave');
};

subtest 'an unrelated config write does not lose the user' => sub {
    my $writer = Purl::Config->new(config_file => $file);
    my $reader = Purl::Config->new(config_file => $file);

    create_user($writer, 'erin', 'erinpassword');

    # A different worker saves an unrelated section. Its own view must have
    # been refreshed first, or the save would write erin back out of existence.
    my $section = $reader->get_section('retention');
    $section->{days} = 90;
    $reader->set_section('retention', $section);

    my $third = Purl::Config->new(config_file => $file);
    my $r = login($third, 'erin', 'erinpassword');
    is $r->{json}{authenticated}, 1, 'erin survived the concurrent unrelated save';

    delete_user($writer, 'erin');
};

done_testing();

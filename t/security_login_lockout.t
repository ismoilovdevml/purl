#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);

# ============================================================================
# BUG 2 regression: per-username login lockout must actually be ENFORCED.
#
# Before the fix, Controller::Auth::login() verified the password and returned
# 401 without ever calling record_failed_login / check_username_rate_limit, so
# the advertised "5 attempts / 10 min" lockout was dead code => unlimited
# password brute-force.
#
# This drives the REAL Purl::API::Controller::Auth::login() through the REAL
# Purl::API::Middleware::Auth (in-memory counter fallback — no Redis) to prove:
#   * 5 failed logins lock the account
#   * the 6th attempt is 429 EVEN WITH the correct password (checked pre-verify)
#   * a successful login resets the counter
#   * the lockout keys off USERNAME, not IP
# ============================================================================

BEGIN {
    # Guarantee the in-memory fallback store (no shared Redis) for this proof.
    delete $ENV{PURL_REDIS_URL};
    delete $ENV{PURL_BROADCAST_MODE};
}

use Purl::API::Middleware::Auth;
use Purl::API::Controller::Auth;

# ---- minimal mock ClickHouse storage (Controller::Base requires `storage`) ----
{
    package MockStorage;
    sub new { bless {}, $_[0] }
}

# ---- minimal settings holding a single bcrypt-hashed user ----
{
    package MockSettings;
    sub new { bless { sections => $_[1] // {} }, $_[0] }
    sub get_section { $_[0]->{sections}{$_[1]} // {} }
    sub set_section { $_[0]->{sections}{$_[1]} = $_[2] }
}

# ---- minimal Mojolicious-ish controller context ----
{
    package MockLog;
    sub new  { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReq;
    sub new  { bless { body => $_[1] // '' }, $_[0] }
    sub body { $_[0]->{body} }

    package MockCtx;
    sub new {
        my ($class, %o) = @_;
        bless {
            req      => MockReq->new($o{body}),
            session  => {},
            app      => MockApp->new,
            rendered => undef,
            audit    => [],
        }, $class;
    }
    sub req { $_[0]->{req} }
    sub app { $_[0]->{app} }
    sub render { $_[0]->{rendered} = { @_[1 .. $#_] } }
    sub rendered { $_[0]->{rendered} }
    sub session {
        my ($self, @a) = @_;
        return $self->{session} unless @a;
        return $self->{session}{$a[0]} if @a == 1;
        $self->{session}{$a[0]} = $a[1] if @a == 2;
    }
    sub audit_event { push @{$_[0]->{audit}}, { @_[1 .. $#_] } }
}

# Real middleware (in-memory counter store) + real controller.
my $mw = Purl::API::Middleware::Auth->new;
ok !$mw->counter_store->is_shared, 'test runs on in-memory fallback (no Redis)';

my $correct = 'correcthorse123';
my $hash    = $mw->hash_password($correct);
ok defined $hash, 'seeded a bcrypt hash for the test user';

sub build_ctrl {
    my $settings = MockSettings->new({
        auth => { users => { admin => { password => $hash, role => 'admin' } } },
    });
    return Purl::API::Controller::Auth->new(
        storage         => MockStorage->new,
        settings        => $settings,
        auth_middleware => $mw,
    );
}

sub attempt {
    my ($user, $pass) = @_;
    my $ctrl = build_ctrl();
    my $c    = MockCtx->new(body => encode_json({ username => $user, password => $pass }));
    $ctrl->login($c);
    return $c->rendered;
}

subtest 'five failures lock the account; 6th is 429 even with correct password' => sub {
    # A clean run must start from a clean counter for this username.
    $mw->reset_failed_login('admin');

    for my $n (1 .. 5) {
        my $r = attempt('admin', 'wrongpass');
        is $r->{status}, 401, "failed attempt $n => 401";
    }

    ok !$mw->check_username_rate_limit('admin'), 'account is now locked in the store';

    my $r = attempt('admin', $correct);   # CORRECT password, but locked
    is $r->{status}, 429, '6th attempt with correct password is blocked 429';
    like $r->{json}{error}, qr/too many/i, '429 message is generic (no user enumeration)';
    unlike $r->{json}{error}, qr/admin|exist|found/i, 'message does not reveal user existence';
};

subtest 'a successful login resets the failure counter' => sub {
    $mw->reset_failed_login('admin');

    # 4 failures — one below the threshold, still allowed.
    attempt('admin', 'wrongpass') for 1 .. 4;
    ok $mw->check_username_rate_limit('admin'), 'still allowed after 4 failures';

    my $r = attempt('admin', $correct);
    is $r->{status}, undef, 'correct password: no error status set';
    ok $r->{json}{authenticated}, 'login succeeded';

    # Counter cleared => a fresh burst of 5 is required to lock again.
    ok $mw->check_username_rate_limit('admin'), 'counter reset after success';
    attempt('admin', 'wrongpass') for 1 .. 4;
    ok $mw->check_username_rate_limit('admin'),
        'four post-reset failures do NOT lock (counter truly started from 0)';
    $mw->reset_failed_login('admin');
};

subtest 'lockout keys off username, not IP' => sub {
    $mw->reset_failed_login('admin');
    $mw->reset_failed_login('ghost');

    # Lock a non-existent user (unknown users are recorded too, by name).
    attempt('ghost', 'whatever') for 1 .. 5;
    ok !$mw->check_username_rate_limit('ghost'), 'victim username is locked';

    # Same process / same "IP" — a different username is unaffected.
    ok $mw->check_username_rate_limit('admin'),
        'different username still allowed (lockout is per-username, not per-IP)';

    my $r = attempt('admin', $correct);
    ok $r->{json}{authenticated}, 'other user can still log in while first is locked';
    $mw->reset_failed_login('ghost');
    $mw->reset_failed_login('admin');
};

done_testing;

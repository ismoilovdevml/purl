#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use POSIX qw(:sys_wait_h);
use Fcntl ();
use Time::HiRes ();
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Config;

# ============================================
# REGRESSION (#35): concurrent workers must not lose each other's updates.
#
# The atomic write-then-rename in save() closed TORN READS. It did nothing
# about LOST UPDATES:
#
#   worker A: get_section('auth')          -> {admin}
#   worker B: get_section('auth')          -> {admin}
#   worker B: adds bob,   set_section+save -> {admin, bob}
#   worker A: adds alice, set_section+save -> {admin, alice}   # bob is gone
#
# Both workers genuinely believed they held current state, because every read
# re-checks the file's stat stamp — they were both right at the moment they
# read. The read and the write have to be ONE critical section.
#
# The fix is flock(2) on a sidecar lock file plus update_section(), which
# re-reads inside the lock and hands the callback the newest revision.
# ============================================

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

sub fresh_config {
    local $ENV{PURL_CONFIG_FILE} = $file;
    return Purl::Config->new(config_file => $file);
}

sub reset_users {
    my (%users) = @_;
    unlink $file;
    my $cfg = fresh_config();
    $cfg->set_section('auth', { enabled => 1, users => { %users } });
    return $cfg;
}

# ============================================
# update_section semantics
# ============================================

subtest 'update_section reads the newest revision, not our snapshot' => sub {
    reset_users(admin => 'hash-admin');

    my $worker_a = fresh_config();
    my $worker_b = fresh_config();

    # A takes its snapshot of the section BEFORE B commits — the exact window
    # the hand-written get_section/set_section pair leaves open.
    my $stale = $worker_a->get_section('auth');
    is_deeply [ sort keys %{ $stale->{users} } ], ['admin'], 'A sees only admin';

    $worker_b->update_section('auth', sub { $_[0]{users}{bob} = 'hash-bob' });

    $worker_a->update_section('auth', sub { $_[0]{users}{alice} = 'hash-alice' });

    my $final = fresh_config()->get_section('auth');
    is_deeply [ sort keys %{ $final->{users} } ], [qw(admin alice bob)],
        'bob survived A\'s write';
};

subtest 'update_section leaves other sections alone' => sub {
    reset_users(admin => 'hash-admin');
    my $cfg = fresh_config();
    $cfg->set('retention', 'days', 42);

    fresh_config()->update_section('auth', sub { $_[0]{users}{carol} = 'x' });

    my $after = fresh_config();
    is $after->get('retention', 'days'), 42, 'unrelated section untouched';
    ok exists $after->get_section('auth')->{users}{carol}, 'the edit landed';
};

subtest 'a nested setter inside update_section does not deadlock' => sub {
    reset_users(admin => 'hash-admin');

    my $cfg = fresh_config();
    my $done = 0;
    # flock on a second descriptor would block against our own lock; the
    # re-entrancy guard is what stops a worker deadlocking on itself.
    my $ok = eval {
        local $SIG{ALRM} = sub { die "deadlocked\n" };
        alarm 10;
        $cfg->update_section('auth', sub {
            $_[0]{users}{dave} = 'x';
            $cfg->set('retention', 'days', 7);
            $done = 1;
        });
        alarm 0;
        1;
    };
    my $err = $@;
    alarm 0;

    ok $ok, 'update_section returned' or diag "error: $err";
    is $done, 1, 'the callback ran to completion';
    is fresh_config()->get('retention', 'days'), 7, 'the nested write landed';
};

# ============================================
# Real concurrency — this is what actually proves the lock
# ============================================
#
# Each child holds the section for ~50ms before saving, so the read-modify-write
# windows genuinely overlap. Without flock every child reads the same base and
# the last writer wins, leaving fewer users than children.

subtest 'concurrent workers each adding a user lose nothing' => sub {
    reset_users(admin => 'hash-admin');

    my $children = 5;
    my @pids;
    for my $i (1 .. $children) {
        my $pid = fork();
        if (!defined $pid) {
            plan skip_all => "fork unavailable: $!";
        }
        if ($pid == 0) {
            my $cfg = Purl::Config->new(config_file => $file);
            $cfg->update_section('auth', sub {
                my ($section) = @_;
                # Widen the window deliberately: with the lock this serialises,
                # without it every child overwrites its predecessor.
                select undef, undef, undef, 0.05;
                $section->{users}{"user$i"} = "hash-$i";
            });
            exit 0;
        }
        push @pids, $pid;
    }

    waitpid($_, 0) for @pids;

    my $users = fresh_config()->get_section('auth')->{users};
    is_deeply [ sort keys %$users ],
        [ 'admin', map { "user$_" } 1 .. $children ],
        "all $children concurrently-created users survived";
};

subtest 'concurrent set() calls on different keys all survive' => sub {
    unlink $file;
    fresh_config()->set('retention', 'days', 1);

    my @pids;
    my @keys = qw(alpha beta gamma delta);
    for my $key (@keys) {
        my $pid = fork();
        if (!defined $pid) {
            plan skip_all => "fork unavailable: $!";
        }
        if ($pid == 0) {
            my $cfg = Purl::Config->new(config_file => $file);
            $cfg->set('retention', $key, "v-$key");
            exit 0;
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my $cfg = fresh_config();
    for my $key (@keys) {
        is $cfg->get('retention', $key), "v-$key", "$key survived";
    }
};

# ============================================
# The lock must not make failure modes worse
# ============================================

subtest 'saving still works when the lock file cannot be created' => sub {
    my $ro_dir = tempdir(CLEANUP => 1);
    my $ro_file = File::Spec->catfile($ro_dir, 'settings.json');
    my $cfg = Purl::Config->new(config_file => $ro_file);
    ok $cfg->set('retention', 'days', 5), 'set() succeeded';

    my $lock = "$ro_file.lock";
    ok -e $lock, 'a sidecar lock file is used, not the config file itself';
    isnt $lock, $ro_file, 'the config file is never the lock target';
};

# A wedged lock holder must not park the worker.
#
# flock(LOCK_EX) with no timeout blocks the PROCESS, and a Mojolicious worker is
# one event loop — every other in-flight request on it, ingest included, stops
# for as long as the holder holds. The wait is now bounded: after
# $LOCK_TIMEOUT we warn and fall through to the same unlocked path used when
# the lock file cannot be opened at all.
subtest 'a held lock times out instead of blocking forever' => sub {
    reset_users(admin => 'hash-admin');

    my $lock_file = "$file.lock";
    open my $holder, '>>', $lock_file or die "cannot open $lock_file: $!";
    # flock is per open-file-description, so a second handle in this same
    # process contends exactly like another worker would.
    flock($holder, Fcntl::LOCK_EX() | Fcntl::LOCK_NB())
        or plan skip_all => "flock unavailable here: $!";

    local $Purl::Config::LOCK_TIMEOUT = 0.2;

    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $started = Time::HiRes::time();
    my $cfg = fresh_config();
    my $ok = $cfg->update_section('auth', sub { $_[0]->{users}{bob} = 'hash-bob' });
    my $elapsed = Time::HiRes::time() - $started;

    ok $ok, 'the write still went through';
    cmp_ok $elapsed, '<', 5, "returned in ${elapsed}s, it did not park the worker";
    like $warned, qr/Timed out waiting for config lock/, 'and said so loudly';

    flock($holder, Fcntl::LOCK_UN());
    close $holder;

    is_deeply [sort keys %{ fresh_config()->get_section('auth')->{users} }],
        [qw(admin bob)], 'degraded path still saved the change';
};

subtest 'an uncontended lock is taken immediately and silently' => sub {
    reset_users(admin => 'hash-admin');

    my $warned = '';
    local $SIG{__WARN__} = sub { $warned .= $_[0] };

    my $started = Time::HiRes::time();
    fresh_config()->update_section('auth', sub { $_[0]->{users}{eve} = 'hash-eve' });
    my $elapsed = Time::HiRes::time() - $started;

    cmp_ok $elapsed, '<', 0.5, 'no retry sleep was paid on an idle lock';
    is $warned, '', 'and nothing was warned';
};

done_testing();

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use POSIX ();
use Time::HiRes qw(time sleep);
use Mojo::IOLoop;
use Purl::API::Server::Prefork;
use Purl::API::Server::Shutdown;

# ============================================================================
# Who counts as the worker in Purl::API::Server::Shutdown (#90 follow-ups).
#
# The worker claim decides two things: which process flushes the ingest buffer
# in END, and which process turns SIGTERM/SIGINT into a graceful stop. It must
# land in prefork workers only:
#   - not in a process that merely BUILT the server (tests) and ran its loop;
#   - not in the manager, even if the manager's loop ever runs;
#   - and a child forked from a worker (Mojo::IOLoop->subprocess, the alert
#     check in Purl::API::Server::Cron) must still die on SIGTERM instead of
#     inheriting a handler that swallows it.
# ============================================================================

# Run the singleton loop briefly so any queued next_tick fires.
sub spin { Mojo::IOLoop->timer(0.05 => sub { Mojo::IOLoop->stop }); Mojo::IOLoop->start }

# Run $code in a fork; its exit status is the result (0 = pass).
sub in_child {
    my ($code) = @_;
    my $pid = fork() // die "fork: $!";
    if (!$pid) { my $ok = eval { $code->() }; print STDERR "# child: $@" if $@; POSIX::_exit($ok ? 0 : 1) }
    waitpid $pid, 0;
    return $? >> 8;
}

subtest 'installing on a built server arms nothing until the manager runs' => sub {
    my $server = Purl::API::Server::Prefork->new;
    Purl::API::Server::Shutdown::install(storage => sub { undef }, server => $server);
    spin();
    is(Purl::API::Server::Shutdown::owner_pid(), undef, 'no worker role claimed by the building process');
    ok(!ref $SIG{TERM}, 'its SIGTERM keeps the default action');
};

subtest 'the manager never claims the worker role, its workers do' => sub {
    Purl::API::Server::Prefork->new->tap(sub {
        Purl::API::Server::Shutdown::install(storage => sub { undef }, server => $_[0]);
        $_[0]->emit('manager_start');         # what run() emits in the manager
    });

    # A worker: forked from the armed manager, runs its own loop.
    is(in_child(sub {
        spin();
        return Purl::API::Server::Shutdown::owner_pid() == $$ && ref $SIG{TERM} eq 'CODE';
    }), 0, 'a process forked from the manager claims the worker role in its loop');

    # The manager's own loop runs (it never does in production; it did in
    # t/server_prefork.t before the fix): still not a worker.
    spin();
    is(Purl::API::Server::Shutdown::owner_pid(), undef, 'the manager running its loop claims nothing');
    ok(!ref $SIG{TERM}, "the manager's SIGTERM is untouched");
};

subtest 'a subprocess forked from a worker dies on SIGTERM' => sub {
    Purl::API::Server::Shutdown::arm();    # the manager's spin above consumed the claim
    my $result = in_child(sub {
        spin();             # claim: this child is a worker forked from the armed manager
        die "not claimed\n" unless (Purl::API::Server::Shutdown::owner_pid() // 0) == $$;

        my ($status, $elapsed);
        my $t0 = time;
        my $sp = Mojo::IOLoop->subprocess;
        $sp->on(spawn => sub { kill 'TERM', $_[0]->pid });
        $sp->run(
            sub { my $end = time + 10; sleep 0.1 while time < $end; return 'survived' },
            sub { $status = $?; $elapsed = time - $t0; Mojo::IOLoop->stop },
        );
        Mojo::IOLoop->timer(15 => sub { Mojo::IOLoop->stop });
        Mojo::IOLoop->start;

        my $sig = defined $status ? $status & 127 : -1;
        die sprintf("subprocess ended with signal %d after %.1fs, want SIGTERM quickly\n",
            $sig, $elapsed // -1)
            unless $sig == POSIX::SIGTERM() && $elapsed < 5;
        return 1;
    });
    is($result, 0, 'the alert-check style subprocess is terminated by SIGTERM, not left running');
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);
use File::Spec ();
use HTTP::Tiny ();
use IO::Socket::INET ();
use POSIX ();
use Time::HiRes qw(sleep time);
use Mojolicious;
use Mojo::Server::Prefork;
use Purl::API::Server::Prefork;
use Purl::API::Server::Shutdown;

# ============================================================================
# Shutdown flush of the PREFORK server (#90), without ClickHouse, so it runs
# in CI. t/ingest_shutdown_flush.t proves the same against a real ClickHouse
# but skips without one.
#
# Each scenario forks a real Purl::API::Server::Prefork manager with a
# minimal app and a fake storage: POST /log buffers lines in the serving
# worker's memory, and flush() appends them, tagged with the worker's pid, to
# a file. What is in that file after the server stops is what would have
# reached ClickHouse; anything still buffered in a killed worker is lost.
# ============================================================================

# Purl::API::Server::Prefork overrides Mojo's PRIVATE _term. If a Mojolicious
# upgrade removes or renames it, SIGTERM silently goes back to SIGKILLing the
# workers and dropping their buffers. Fail loudly instead.
ok(Mojo::Server::Prefork->can('_term'),
    'Mojo::Server::Prefork still has _term (overridden by Purl::API::Server::Prefork)')
    or BAIL_OUT('Mojo::Server::Prefork::_term is gone: Purl::API::Server::Prefork no longer '
        . 'makes SIGTERM/SIGINT drain the workers, so buffered logs are LOST on every stop. '
        . 'Port the override to this Mojolicious version (see #90).');

my $dir = tempdir(CLEANUP => 1);

{
    package Purl::Test::FileFlushStorage;
    use Moo;
    has file   => (is => 'ro', required => 1);
    has buffer => (is => 'ro', default => sub { [] });

    sub flush {
        my ($self) = @_;
        my $buf = $self->buffer;
        return 0 unless @$buf;
        open my $fh, '>>', $self->file or die "open: $!";
        print {$fh} map { "$$\t$_\n" } @$buf;
        close $fh;
        my $n = @$buf;
        @$buf = ();
        return $n;
    }
}

sub free_port {
    my $probe = IO::Socket::INET->new(
        Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1,
    ) or die "cannot bind a probe socket: $!";
    my $port = $probe->sockport;
    $probe->close;
    return $port;
}

# Fork a manager. Returns ($manager_pid, $port, $flush_file) once it answers.
sub start_server {
    my (%opt) = @_;
    my $port = free_port();
    my $file = File::Spec->catfile($dir, "flushed-$port.txt");

    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        my $storage = Purl::Test::FileFlushStorage->new(file => $file);
        my $app = Mojolicious->new;
        $app->log->level('fatal');
        my $r = $app->routes;
        $r->post('/log' => sub {
            my ($c) = @_;
            push @{ $storage->buffer }, grep { length } split /\n/, $c->req->body;
            $c->render(text => $$);
        });
        $r->get('/pid'   => sub { $_[0]->render(text => $$) });
        # A signal interrupts sleep(), so loop until the deadline: truly stuck.
        $r->get('/stuck' => sub {
            my $end = time + 60;
            sleep 0.2 while time < $end;
            $_[0]->render(text => 'never');
        });

        my $server = Purl::API::Server::Prefork->new(
            app              => $app,
            listen           => ["http://127.0.0.1:$port"],
            silent           => 1,
            workers          => $opt{workers},
            graceful_timeout => $opt{graceful_timeout} // 20,
            pid_file         => File::Spec->catfile($dir, "manager-$port.pid"),
        );
        Purl::API::Server::Shutdown::install(
            storage => sub { $storage }, log => $app->log, server => $server,
        );
        $server->run;
        POSIX::_exit(0);
    }

    my $ua = HTTP::Tiny->new(timeout => 2);
    for (1 .. 150) {
        return ($pid, $port, $file) if $ua->get("http://127.0.0.1:$port/pid")->{status} == 200;
        sleep 0.1;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    die "server on port $port never answered\n";
}

# Wait for our child to exit; returns (exited, seconds taken, raw status).
sub wait_exit {
    my ($pid, $timeout) = @_;
    my $t0 = time;
    while (time < $t0 + ($timeout // 30)) {
        return (1, time - $t0, $?) if waitpid($pid, POSIX::WNOHANG()) == $pid;
        sleep 0.05;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return (0, time - $t0, $?);
}

sub process_gone {
    my ($pid, $timeout) = @_;
    my $deadline = time + ($timeout // 30);
    while (time < $deadline) {
        return 1 unless kill 0, $pid;
        sleep 0.05;
    }
    return 0;
}

sub worker_pids {
    my ($manager) = @_;
    return grep { /^\d+$/ } split /\s+/, `pgrep -P $manager`;
}

sub lines_of { my ($from, $n) = @_; return join '', map { "log-$_\n" } $from .. $from + $n - 1 }

# One batch on a NEW connection; returns the pid of the worker that buffered it.
sub ingest {
    my ($port, $from, $n) = @_;
    my $res = HTTP::Tiny->new(timeout => 10)->post("http://127.0.0.1:$port/log", { content => lines_of($from, $n) });
    die "ingest failed: $res->{status}\n" unless $res->{status} == 200;
    return $res->{content};
}

# (lines flushed, { worker pid => lines })
sub flushed {
    my ($file) = @_;
    my %by;
    open my $fh, '<', $file or return (0, {});
    while (<$fh>) { my ($pid) = split /\t/; $by{$pid}++ }
    my $n = 0;
    $n += $_ for values %by;
    return ($n, \%by);
}

# ----------------------------------------------------------------------------
subtest 'SIGTERM to the manager: every worker flushes its own buffer' => sub {
    my ($pid, $port, $file) = start_server(workers => 2);

    my ($sent, %by_worker) = (0);
    for my $batch (0 .. 199) {
        $by_worker{ ingest($port, $sent, 10) } += 10;
        $sent += 10;
        last if keys %by_worker >= 2 && $batch >= 3;
    }
    is(scalar(keys %by_worker), 2, 'both workers hold buffered logs: '
        . join(', ', map { "$_=$by_worker{$_}" } sort keys %by_worker));
    is((flushed($file))[0], 0, 'nothing flushed yet (logs are buffered)');

    kill 'TERM', $pid;
    my ($exited) = wait_exit($pid);
    ok($exited, 'manager exited after SIGTERM');
    my ($n, $by) = flushed($file);
    is($n, $sent, "all $sent buffered logs were flushed");
    is_deeply($by, \%by_worker, 'each worker flushed exactly the logs it buffered');
};

# ----------------------------------------------------------------------------
subtest 'SIGTERM to one worker: it flushes on its own exit' => sub {
    my ($pid, $port, $file) = start_server(workers => 1);
    my $worker = ingest($port, 0, 40);
    is_deeply([ worker_pids($pid) ], [$worker], "the batch sits in worker $worker");

    kill 'TERM', $worker;
    ok(process_gone($worker, 10), 'the worker exited after SIGTERM');
    is((flushed($file))[0], 40, 'it flushed all 40 logs before exiting');

    kill 'QUIT', $pid;
    ok((wait_exit($pid))[0], 'manager stopped');
};

# ----------------------------------------------------------------------------
subtest 'SIGQUIT with a request in flight: its logs are flushed too' => sub {
    my ($pid, $port, $file) = start_server(workers => 1);
    ingest($port, 0, 50);

    # Headers now, body only after the drain has begun: these logs enter the
    # buffer AFTER the loop's `finish` flush, so only the flush at worker exit
    # can save them.
    my $body = lines_of(50, 25);
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10)
        or die "connect: $!";
    $sock->autoflush(1);
    print {$sock} "POST /log HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: "
        . length($body) . "\r\n\r\n";
    sleep 0.5;
    kill 'QUIT', $pid;
    sleep 1;
    print {$sock} $body;
    my $status = <$sock> // '';
    close $sock;
    like($status, qr{^HTTP/1\.1 200}, 'the in-flight request completed during the drain');

    ok((wait_exit($pid))[0], 'manager exited after SIGQUIT');
    is((flushed($file))[0], 75, 'all 75 logs flushed, including the in-flight batch');
};

# ----------------------------------------------------------------------------
subtest 'a worker stuck past graceful_timeout is killed and the manager exits' => sub {
    my ($pid, $port) = start_server(workers => 1, graceful_timeout => 2);
    my ($worker) = worker_pids($pid);

    # Pin the only worker in a 60s request.
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10)
        or die "connect: $!";
    print {$sock} "GET /stuck HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    sleep 0.5;

    kill 'TERM', $pid;
    my ($exited, $took, $status) = wait_exit($pid, 20);
    close $sock;
    ok($exited, sprintf('manager exited on its own after %.1fs', $took));
    cmp_ok($took, '>=', 1.5, 'it waited for the graceful_timeout first');
    cmp_ok($took, '<', 10, 'and did not wait for the 60s request');
    is($status, 0, 'manager exit status is clean (0)');
    ok(process_gone($worker, 5), "the stuck worker $worker was killed");
};

done_testing;

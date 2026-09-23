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
use Mojo::JSON qw(encode_json);

# ============================================================================
# REAL shutdown-flush test (#90) — requires a live ClickHouse.
#
# Logs accepted by POST /api/logs sit in the ingest buffer of the worker that
# served them (non-durable mode) until the next flush. Before #90 the only
# flush at exit was DEMOLISH during global destruction, and a SIGTERM made the
# prefork manager SIGKILL its workers — so every restart / rolling deploy
# silently dropped the last buffered batch.
#
# Every scenario below starts the REAL prefork server (build_prefork->run)
# against a REAL ClickHouse, with the time-based flush pushed out to an hour so
# nothing leaves the buffer on its own, ingests logs, stops the server with a
# signal and then counts the rows in ClickHouse. Nothing is mocked.
#
# Connection: PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD/DATABASE (same as the
# app). No reachable ClickHouse => skip_all with a clear message, never a fake
# pass.
# ============================================================================

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
    database => $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl',
);

my $http = HTTP::Tiny->new(timeout => 10);

sub ch_url {
    my (%params) = @_;
    my $q = $http->www_form_urlencode({
        user => $conn{username}, password => $conn{password}, %params,
    });
    return "http://$conn{host}:$conn{port}/?$q";
}

my $reachable = $http->post(ch_url(), { content => 'SELECT 1' })->{success};
plan skip_all =>
    "No reachable ClickHouse at $conn{host}:$conn{port}. The shutdown flush is "
  . 'therefore UNVERIFIED in this run. Point PURL_CLICKHOUSE_* at a live instance.'
    unless $reachable;

my $dir = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_DIR}           = $dir;
$ENV{PURL_CONFIG_FILE}          = File::Spec->catfile($dir, 'settings.json');
$ENV{PURL_BROADCAST_SPOOL}      = File::Spec->catfile($dir, 'live-tail.spool');
$ENV{PURL_CRON_LOCK_FILE}       = File::Spec->catfile($dir, 'cron.lock');
$ENV{PURL_BROADCAST_MODE}       = 'local';
$ENV{PURL_ALERT_CHECK_INTERVAL} = '0';
$ENV{PURL_API_KEYS}             = 'shutdown-flush-test-key';
delete $ENV{PURL_REDIS_URL};
delete $ENV{PURL_INGEST_DURABLE};

require Purl::Storage::ClickHouse;
require Purl::API::Server;
{
    # The real ClickHouse storage, plus one thing: each buffered log records
    # the pid of the worker that buffered it (in `host`), so the test can prove
    # that EVERY worker held — and flushed — its own share.
    package Purl::Test::WorkerTaggedStorage;
    use Moo;
    extends 'Purl::Storage::ClickHouse';
    before insert => sub { $_[1]{host} = "worker-$$" };
}
{
    no warnings 'redefine';
    # Only the flush triggers are pushed out of reach so the logs provably stay
    # buffered until shutdown.
    *Purl::API::Server::_build_storage = sub {
        return Purl::Test::WorkerTaggedStorage->new(
            %conn,
            buffer_size    => 1_000_000,
            flush_interval => 3600,
        );
    };
}

my $server = Purl::API::Server->create(config => {});
$server->setup_routes;
Purl::API::Server::app()->log->level('fatal');

# Test-only route answering with the serving worker's pid, moved ahead of the
# SPA catch-all. Asked on the same keep-alive connection as an ingest, it
# tells the test which worker buffered that batch.
Purl::API::Server::app()->routes->get('/purl-test-pid' => sub { $_[0]->render(text => $$) });
{
    my $routes = Purl::API::Server::app()->routes;
    unshift @{ $routes->children }, pop @{ $routes->children };
}

sub free_port {
    my $probe = IO::Socket::INET->new(
        Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1,
    ) or die "cannot bind a probe socket: $!";
    my $port = $probe->sockport;
    $probe->close;
    return $port;
}

# Fork the manager; returns ($manager_pid, $port) once /api/health answers.
sub start_server {
    my (%opt) = @_;
    my $port = free_port();
    my $pid  = fork() // die "fork: $!";
    if (!$pid) {
        my $srv = $server->build_prefork(
            host => '127.0.0.1', port => $port, workers => $opt{workers},
        );
        $srv->pid_file(File::Spec->catfile($dir, "manager-$$.pid"));
        $srv->run;
        POSIX::_exit(0);
    }
    my $ua = HTTP::Tiny->new(timeout => 2);
    for (1 .. 150) {
        return ($pid, $port) if $ua->get("http://127.0.0.1:$port/api/health")->{status} == 200;
        sleep 0.1;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    die "server on port $port never became healthy\n";
}

sub wait_exit {
    my ($pid, $timeout) = @_;
    my $deadline = time + ($timeout // 30);
    while (time < $deadline) {
        return 1 if waitpid($pid, POSIX::WNOHANG()) == $pid;
        sleep 0.1;
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return 0;
}

sub process_gone {
    my ($pid, $timeout) = @_;
    my $deadline = time + ($timeout // 30);
    while (time < $deadline) {
        return 1 unless kill 0, $pid;
        sleep 0.1;
    }
    return 0;
}

sub worker_pids {
    my ($manager) = @_;
    my @pids = grep { /^\d+$/ } split /\s+/, `pgrep -P $manager`;
    return @pids;
}

sub ingest_body {
    my ($marker, $from, $count) = @_;
    return encode_json([ map {
        { service => $marker, level => 'INFO', message => "shutdown-flush #$_" }
    } $from .. $from + $count - 1 ]);
}

# One batch on a NEW keep-alive connection. Returns (status, pid of the worker
# that buffered it) — the pid is asked on the same connection, so the same
# worker answers it.
sub ingest {
    my ($port, $marker, $from, $count) = @_;
    my $ua  = HTTP::Tiny->new(timeout => 10, keep_alive => 1);
    my $res = $ua->post("http://127.0.0.1:$port/api/logs", {
        headers => {
            'Content-Type' => 'application/json',
            'X-API-Key'    => $ENV{PURL_API_KEYS},
        },
        content => ingest_body($marker, $from, $count),
    });
    my $pid = $ua->get("http://127.0.0.1:$port/purl-test-pid")->{content};
    return wantarray ? ($res->{status}, $pid) : $res->{status};
}

# Rows for $marker, polled because non-durable inserts are async in ClickHouse.
# The marker goes in as a bound query parameter, never interpolated.
sub rows_for {
    my ($marker, $want) = @_;
    my $n = -1;
    for (1 .. 50) {
        my $res = $http->post(
            ch_url(param_svc => $marker),
            { content => "SELECT count() FROM $conn{database}.logs WHERE service = {svc:String}" },
        );
        $n = $res->{success} ? ($res->{content} =~ /(\d+)/)[0] : -1;
        return $n if defined $want && $n == $want;
        sleep 0.2;
    }
    return $n;
}

sub workers_seen {
    my ($marker) = @_;
    my $res = $http->post(
        ch_url(param_svc => $marker),
        { content => "SELECT uniqExact(host) FROM $conn{database}.logs WHERE service = {svc:String}" },
    );
    return $res->{success} ? ($res->{content} =~ /(\d+)/)[0] : -1;
}

sub marker { return sprintf 'purl-t90-%s-%d-%d', shift, $$, int(time * 1000) }

# ----------------------------------------------------------------------------
# 1. SIGTERM to the manager with 2 workers: every worker flushes its own buffer.
#    Before #90 the manager answered SIGTERM by SIGKILLing the workers.
# ----------------------------------------------------------------------------
subtest 'SIGTERM to the manager flushes every worker buffer' => sub {
    my $marker = marker('term');
    my ($pid, $port) = start_server(workers => 2);

    # New connections until BOTH workers hold buffered logs (the kernel picks
    # the accepting worker, so keep going until each has served a batch).
    my ($sent, %by_worker, $bad) = (0);
    for my $batch (0 .. 99) {
        my ($status, $pid) = ingest($port, $marker, $sent, 20);
        $bad++ if $status != 200;
        $sent += 20;
        $by_worker{$pid} += 20;
        last if keys %by_worker >= 2 && $batch >= 4;
    }
    ok !$bad, "every batch accepted ($sent logs)";
    is scalar(keys %by_worker), 2, 'both workers are holding buffered logs: '
        . join(', ', map { "$_=$by_worker{$_}" } sort keys %by_worker);
    is rows_for($marker, 0), 0, 'nothing reached ClickHouse yet (logs are buffered)';

    kill 'TERM', $pid;
    ok wait_exit($pid), 'server exited after SIGTERM';
    is rows_for($marker, $sent), $sent, "all $sent buffered logs are in ClickHouse after SIGTERM";
    is workers_seen($marker), 2, 'both workers held buffered logs and each flushed its own';
};

# ----------------------------------------------------------------------------
# 2. SIGQUIT (graceful drain) with a request still IN FLIGHT: its logs enter
#    the buffer after the loop's `finish` hook already ran, so only a flush at
#    worker exit (before global destruction) can save them.
# ----------------------------------------------------------------------------
subtest 'SIGQUIT flushes logs from a request that was in flight' => sub {
    my $marker = marker('quit');
    my ($pid, $port) = start_server(workers => 1);

    is ingest($port, $marker, 0, 50), 200, 'first batch accepted';

    my $body = ingest_body($marker, 50, 25);
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Timeout => 10)
        or die "connect: $!";
    $sock->autoflush(1);
    print {$sock} "POST /api/logs HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        . "X-API-Key: $ENV{PURL_API_KEYS}\r\nContent-Type: application/json\r\n"
        . 'Content-Length: ' . length($body) . "\r\n\r\n";
    sleep 0.5;                        # the worker has accepted the request
    kill 'QUIT', $pid;
    sleep 1;                          # graceful stop has begun (finish emitted)
    print {$sock} $body;
    my $status_line = <$sock> // '';
    close $sock;
    like $status_line, qr{^HTTP/1\.1 200}, 'in-flight request completed with 200 during the drain';

    ok wait_exit($pid), 'server exited after SIGQUIT';
    is rows_for($marker, 75), 75, 'all 75 logs (incl. the in-flight batch) are in ClickHouse';
};

# ----------------------------------------------------------------------------
# 3. A single WORKER receiving SIGTERM (process-group signal, OOM-killer
#    politeness, etc.) flushes on its own exit — before the manager stops.
# ----------------------------------------------------------------------------
subtest 'SIGTERM to one worker flushes that worker on its own exit' => sub {
    my $marker = marker('worker');
    my ($pid, $port) = start_server(workers => 1);

    is ingest($port, $marker, 0, 40), 200, 'batch accepted';
    my ($worker) = worker_pids($pid);
    ok $worker, "found the worker pid ($worker)" or return;

    kill 'TERM', $worker;
    ok process_gone($worker), 'worker exited after SIGTERM';
    is rows_for($marker, 40), 40, 'the worker flushed all 40 logs before exiting';

    kill 'QUIT', $pid;
    ok wait_exit($pid), 'manager stopped';
};

done_testing;

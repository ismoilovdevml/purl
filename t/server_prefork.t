use strict;
use warnings;
use 5.024;

use Test::More;
use Time::HiRes qw(time sleep);
use File::Spec ();
use IO::Socket::INET ();
use POSIX ();

# ============================================================
# TASK C1 — prefork server conversion.
#
# This file proves three things:
#   1. run() drives a Mojo::Server::Prefork with N workers (not the
#      old single-process `daemon`), built via build_prefork().
#   2. CONTRACT: controllers see config->{pipeline} (and config->{server})
#      so PURL_PIPELINE_REGEX_* env overrides reach the ReDoS guard.
#   3. THE CORE WIN: with >1 worker a slow/blocking request no longer
#      blocks concurrent requests (e.g. /api/health) — impossible under
#      single-process `daemon`.
# ============================================================

# ------------------------------------------------------------
# Env overrides set BEFORE Purl::Config is instantiated, so the folded
# config reflects them (ENV > file > default).
# ------------------------------------------------------------
BEGIN {
    $ENV{PURL_PIPELINE_REGEX_TIMEOUT_MS} = 777;
    $ENV{PURL_PIPELINE_REGEX_MAX_LENGTH} = 333;
    $ENV{PURL_WORKERS}                   = 3;
    $ENV{PURL_GRACEFUL_TIMEOUT}          = 33;
    # Keep Config from touching a real settings file.
    $ENV{PURL_CONFIG_FILE} //= File::Spec->catfile(File::Spec->tmpdir, "purl-prefork-$$.json");
}

# ------------------------------------------------------------
# Minimal in-memory storage mock: keeps /api/health FAST (no ClickHouse).
# ------------------------------------------------------------
{
    package Purl::Storage::InMemory;
    use Moo;
    has '_logs' => (is => 'rw', default => sub { [] });
    sub insert                 { push @{$_[0]->_logs}, $_[1] }
    sub insert_batch           { push @{$_[0]->_logs}, @{$_[1]} }
    sub flush                  { 1 }
    sub maybe_flush            { }
    sub search                 { [] }
    sub count                  { 0 }
    sub stats                  { { total_logs => 0, db_size_bytes => 0, db_size_mb => 0 } }
    sub circuit_breaker_status { { state => 'closed' } }
    sub field_stats            { [] }
    sub get_fields             { [qw(level service host message timestamp)] }
    sub get_metrics            { { queries_total => 0, inserts_total => 0 } }
    sub _init_audit_schema     { 1 }
    sub log_audit_event        { 1 }
}

my $mock_storage = Purl::Storage::InMemory->new;

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $mock_storage };
}

my $server = Purl::API::Server->create(config => {});
my $app    = $server->setup_routes;

# ============================================================
# 1. CONTRACT — config->{pipeline} / config->{server} folded from env.
# ============================================================
my $eff = $server->effective_config;

is($eff->{pipeline}{regex_timeout_ms}, 777,
    'PURL_PIPELINE_REGEX_TIMEOUT_MS folded into config->{pipeline}');
is($eff->{pipeline}{regex_max_length}, 333,
    'PURL_PIPELINE_REGEX_MAX_LENGTH folded into config->{pipeline}');
is($eff->{server}{workers}, 3,
    'PURL_WORKERS folded into config->{server}{workers}');

# End-to-end: the same config hashref handed to controllers (%c_args)
# actually drives the pipeline ReDoS guard bounds in the engine.
require Purl::API::Controller::Pipeline;
my $pipeline_c = Purl::API::Controller::Pipeline->new(
    storage => $mock_storage,
    config  => $server->effective_config,
);
is($pipeline_c->engine->regex_timeout_ms, 777,
    'pipeline engine regex_timeout_ms resolves from folded config (env override reaches engine)');
is($pipeline_c->engine->regex_max_length, 333,
    'pipeline engine regex_max_length resolves from folded config');

# ============================================================
# 2. build_prefork() — a real prefork server, not `daemon`.
# ============================================================
my $pf = $server->build_prefork(host => '127.0.0.1', port => 12345, workers => 4);
isa_ok($pf, 'Mojo::Server::Prefork', 'run() builds a prefork server');
is($pf->workers, 4, 'worker count is honoured');
is_deeply($pf->listen, ['http://127.0.0.1:12345'], 'listen address configured');

# graceful_timeout (#90 follow-up): must stay below the orchestrator's grace
# period, so it comes from config and never silently stays at Mojo's 120s.
is($eff->{server}{graceful_timeout}, 33,
    'PURL_GRACEFUL_TIMEOUT folded into config->{server}{graceful_timeout}');
is($pf->graceful_timeout, 33, 'build_prefork passes the configured graceful_timeout');
is($server->build_prefork(port => 12345, graceful_timeout => 7.5)->graceful_timeout, 7.5,
    'an explicit graceful_timeout wins');
for my $bad ('0', '-5', 'abc', 'inf', 'nan', '') {
    is($server->build_prefork(port => 12345, graceful_timeout => $bad)->graceful_timeout, 50,
        "invalid graceful_timeout '$bad' falls back to the 50s default");
}

# ============================================================
# 3. CONCURRENCY PROOF — a blocking request must not stall others.
# ============================================================

# Register a deliberately slow (blocking) route and move it ahead of the
# SPA catch-all so it is actually matched. A blocking sleep in the handler
# pins the worker's event loop for its whole duration — exactly what a slow
# synchronous ClickHouse query does today.
my $SLOW_SECS = 2;
Purl::API::Server::app()->routes->get('/purl-test-slow' => sub {
    my $c = shift;
    sleep $SLOW_SECS;            # blocks THIS worker's event loop
    $c->render(text => 'slow-done');
});
{
    my $routes = Purl::API::Server::app()->routes;
    unshift @{ $routes->children }, pop @{ $routes->children };
}

# Grab a free ephemeral port.
my $free_port;
{
    my $probe = IO::Socket::INET->new(
        Listen => 5, LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1,
    );
    if ($probe) { $free_port = $probe->sockport; $probe->close; }
}

my $spawned = 0;
my $child_pid;

if ($free_port) {
    $child_pid = fork();
    if (!defined $child_pid) {
        diag("fork() failed: $! — concurrency proof UNPROVEN");
    }
    elsif ($child_pid == 0) {
        # ---- child: run the prefork server (2 workers) ----
        Purl::API::Server::app()->log->level('error');
        my $srv = $server->build_prefork(
            host => '127.0.0.1', port => $free_port, workers => 2,
        );
        $srv->pid_file(File::Spec->catfile(File::Spec->tmpdir, "purl-prefork-srv-$$.pid"));
        $srv->run;           # blocks until SIGQUIT (graceful drain)
        POSIX::_exit(0);
    }
    else {
        $spawned = 1;
    }
}
else {
    diag('could not bind an ephemeral port — concurrency proof UNPROVEN');
}

SKIP: {
    skip 'prefork server could not be spawned in this environment', 3
        unless $spawned;

    require Mojo::UserAgent;
    require Mojo::IOLoop;

    my $base = "http://127.0.0.1:$free_port";

    # --- wait for the server to accept connections (poll health) ---
    my $up = 0;
    my $wait_ua = Mojo::UserAgent->new(connect_timeout => 2, request_timeout => 3);
    for (1 .. 100) {                       # up to ~10s
        my $tx = eval { $wait_ua->get("$base/api/health") };
        if ($tx && $tx->res->code) { $up = 1; last; }
        sleep 0.1;
    }

    unless ($up) {
        diag('server never became reachable — concurrency proof UNPROVEN');
        kill 'QUIT', $child_pid if $child_pid;
        waitpid($child_pid, 0) if $child_pid;
        skip 'server not reachable', 3;
    }

    ok(1, 'prefork server is up and answering /api/health');

    # --- fire a blocking request, then a health request concurrently ---
    # Separate UA objects => separate TCP connections => can land on
    # different workers.
    my $slow_ua = Mojo::UserAgent->new(request_timeout => 10);
    my $fast_ua = Mojo::UserAgent->new(request_timeout => 10);

    my ($slow_done, $health_done, $health_code);
    my $health_t0;

    $slow_ua->get("$base/purl-test-slow" => sub {
        my (undef, $tx) = @_;
        $slow_done = time;
    });

    # Give the slow request time to be accepted and pin its worker.
    Mojo::IOLoop->timer(0.5 => sub {
        $health_t0 = time;
        $fast_ua->get("$base/api/health" => sub {
            my (undef, $tx) = @_;
            $health_done = time;
            $health_code = $tx->res->code;
            Mojo::IOLoop->stop;          # health answered — done proving
        });
    });

    # Safety valve so the loop can't hang forever.
    Mojo::IOLoop->timer($SLOW_SECS + 5 => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;

    my $health_latency = (defined $health_done && defined $health_t0)
        ? $health_done - $health_t0 : undef;

    ok(defined $health_latency && $health_latency < 1.5,
        sprintf('/api/health answered in %.3fs while a %ds blocking request was in flight (concurrent)',
            $health_latency // -1, $SLOW_SECS));

    ok(!defined $slow_done,
        'health returned BEFORE the blocking request finished — proves prefork concurrency (would stall under single-process daemon)');

    diag(sprintf('health_code=%s health_latency=%.3fs slow_finished_before_health=%s',
        $health_code // 'n/a', $health_latency // -1, (defined $slow_done ? 'yes' : 'no')));

    # Regression (#90 follow-up): build_prefork() ran in THIS process and the
    # singleton loop just ran here. The worker claim must not have fired:
    # this test process is not a worker, so its END must not flush and its
    # SIGTERM must keep the default action.
    is(Purl::API::Server::Shutdown::owner_pid(), undef,
        'running the loop in a process that only built the server claims no worker role');
    ok(!ref $SIG{TERM}, 'SIGTERM handler of the building process left untouched');

    # --- graceful shutdown (SIGQUIT) ---
    kill 'QUIT', $child_pid if $child_pid;
    waitpid($child_pid, 0)  if $child_pid;
}

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use IO::Socket::INET;
use IO::Select;
use POSIX ();
use Time::HiRes qw(sleep);
use File::Temp qw(tempdir);

# ============================================
# #115 end to end: fast ingest mode, REAL ClickHouse, outage mid-stream.
#
# Purl talks to ClickHouse through a TCP proxy owned by this test. Logs are
# POSTed to /api/logs one request at a time; halfway through the proxy is
# killed (ClickHouse unreachable: connection refused), requests keep coming
# until ingest pushes back with 503, then the proxy is restored and the
# buffer flushes.
#
# The assertion is the contract: EVERY log that got a 2xx is in ClickHouse
# afterwards, and every log that is not got a non-2xx. Before #115 the batch
# in flight at the outage was acknowledged with 200 and then thrown away.
#
# Own throwaway database (purl_t115_<pid>). Skipped when no ClickHouse.
# ============================================

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
);
my $db = "purl_t115_$$";

my $http = HTTP::Tiny->new(timeout => 30);
my $base = sprintf('http://%s:%d/?user=%s&password=%s',
    $conn{host}, $conn{port}, $conn{username}, $conn{password});

sub ch {
    my ($sql) = @_;
    my $res = $http->post($base, { content => $sql });
    die "ClickHouse: $res->{status} $res->{content}\n" unless $res->{success};
    my $out = $res->{content};
    chomp $out;
    return $out;
}

unless (eval { ch('SELECT 1') eq '1' }) {
    plan skip_all =>
        "No reachable ClickHouse at $conn{host}:$conn{port}. The fast-mode outage contract "
      . "(#115) is therefore UNVERIFIED in this run. Set PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD "
      . "to a live (throwaway) instance to run it.";
}

# --------------------------------------------
# A TCP proxy we can cut and restore.
# --------------------------------------------
my $PROXY_PORT = do {
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1) or die $!;
    my $p = $s->sockport; close $s; $p;
};
my $proxy_pid;

sub proxy_up {
    my $listen = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => $PROXY_PORT, Listen => 16, ReuseAddr => 1,
    ) or die "proxy listen: $!";
    my $pid = fork // die "fork: $!";
    if ($pid) { close $listen; $proxy_pid = $pid; return }

    POSIX::setpgid(0, 0);
    local $SIG{CHLD} = 'IGNORE';
    while (my $client = $listen->accept) {
        my $kid = fork // next;
        if ($kid) { close $client; next }
        my $up = IO::Socket::INET->new(PeerAddr => $conn{host}, PeerPort => $conn{port})
            or POSIX::_exit(0);
        my $sel = IO::Select->new($client, $up);
        OUTER: while (1) {
            for my $fh ($sel->can_read(30)) {
                my $n = sysread($fh, my $buf, 65536);
                last OUTER unless $n;
                syswrite($fh == $client ? $up : $client, $buf) or last OUTER;
            }
        }
        POSIX::_exit(0);
    }
    POSIX::_exit(0);
}

sub proxy_down {
    return unless $proxy_pid;
    kill 'KILL', -$proxy_pid;   # listener and every relay: live connections die too
    waitpid $proxy_pid, 0;
    undef $proxy_pid;
}

END {
    local $?;
    proxy_down();
    eval { ch("DROP DATABASE IF EXISTS $db SYNC") } if $db;
}

proxy_up();

# --------------------------------------------
# The app, fast mode, small buffer so the outage fills it.
# --------------------------------------------
my $cfg_dir = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_DIR}   = $cfg_dir;
$ENV{PURL_CONFIG_FILE}  = "$cfg_dir/settings.json";
$ENV{PURL_AUTH_ENABLED} = 0;

require Purl::Storage::ClickHouse;
my $storage = Purl::Storage::ClickHouse->new(
    %conn, port => $PROXY_PORT, database => $db,
    durable => 0, buffer_size => 10, buffer_max => 40, flush_interval => 0,
    use_query_cache => 0,
);
my @dropped;
$storage->on_ingest_drop(sub { push @dropped, $_[0] }) if $storage->can('on_ingest_drop');

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}
my $app = Purl::API::Server->create(config => { auth => { enabled => 0 } })->setup_routes;
$app->log->unsubscribe('message');
local $SIG{__WARN__} = sub { };   # the outage makes the storage layer warn, by design

require Test::Mojo;
my $t = Test::Mojo->new($app);

my (%acked, %refused);
my $seq = 0;
sub post_one {
    my $marker = sprintf('t115-%06d', ++$seq);
    $t->post_ok('/api/logs' => json => { level => 'info', service => 't115', message => $marker });
    my $code = $t->tx->res->code;
    if ($code >= 200 && $code < 300) { $acked{$marker} = 1 } else { $refused{$marker} = $code }
    return $code;
}

# Phase 1: ClickHouse up.
post_one() for 1 .. 25;
is scalar(keys %refused), 0, 'phase 1: all accepted while ClickHouse is up';

# Phase 2: ClickHouse unreachable mid-stream. Keep posting until backpressure,
# and let the periodic flush fire a few times against the dead backend.
proxy_down();
my $saw_503 = 0;
for (1 .. 80) {
    my $code = post_one();
    $saw_503++ if $code == 503;
    eval { $storage->maybe_flush };   # what the 2s timer does
    last if $saw_503 >= 5;
}
ok $saw_503, 'phase 2: ingest pushes back with 503 once the retry buffer is full';
ok $storage->buffer_depth <= 40, 'buffer stayed within buffer_max (' . $storage->buffer_depth . ')';
ok $storage->buffer_depth > 0, 'unflushed logs are held, not discarded';

# Phase 3: ClickHouse back.
proxy_up();
for (1 .. 20) {
    last if $storage->buffer_depth == 0;
    eval { $storage->flush; 1 } or sleep 0.2;
}
is $storage->buffer_depth, 0, 'phase 3: the held logs are flushed once ClickHouse is back';
post_one() for 1 .. 5;
$storage->flush;

# Fast mode is async_insert with wait=0: give ClickHouse a moment to persist.
my %stored;
for (1 .. 50) {
    %stored = map { $_ => 1 } split /\n/, ch("SELECT message FROM $db.logs WHERE service = 't115'");
    last if !grep { !$stored{$_} } keys %acked;
    sleep 0.2;
}

my @lost = sort grep { !$stored{$_} } keys %acked;
is scalar(@lost), 0, 'no acknowledged log is lost: every 2xx is in ClickHouse'
    or diag "lost: @lost[0 .. ($#lost < 9 ? $#lost : 9)]";
ok scalar(keys %acked) > 30, 'the run acknowledged logs across the outage (' . scalar(keys %acked) . ')';
ok !(grep { $_ != 503 } values %refused), 'every refused log got 503 (retryable), nothing else';
is scalar(@dropped), 0, 'no drops were needed';

my $dupes = ch("SELECT count() - uniqExact(message) FROM $db.logs WHERE service = 't115'");
is $dupes, 0, 'no log written twice';

done_testing;

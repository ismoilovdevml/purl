#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(decode_json);

# ============================================================================
# ROOT CAUSE (#64): live tail delivered NOTHING in production because the
# broadcast bus is per-process and the server runs prefork.
#
#   Server.pm run()  ->  setup_routes()  ->  $broadcaster = Broadcast::Local
#                    ->  build_prefork(...)->run   # fork() x server.workers (4)
#
# Purl::Broadcast::Local keeps its subscribers in a plain in-memory hashref.
# After fork() every worker owns a PRIVATE copy of it, so:
#
#   worker A: holds the /api/logs/stream socket, registers its callback in A
#   worker B: serves POST /api/logs, publishes into B  -> 0 subscribers
#
# The two workers never meet. With the default 4 workers a tailing browser
# sees a log only in the ~1-in-4 case where the same worker happened to accept
# both connections; with a keep-alive ingest agent pinned to one worker it is
# reliably zero. Redis fixes it across replicas but is optional and absent in
# every default deployment (chart replicaCount is 1 — the ONLY thing broken
# there is the fork boundary INSIDE the pod).
#
# The fix is Purl::Broadcast::Prefork: same in-process fan-out, plus an
# append-only spool file on the config volume that every worker in the pod
# reads. No new service, no new dependency.
#
# Point _build_broadcaster back at Purl::Broadcast::Local and the
# "across a fork" subtests below fail (nothing is ever delivered).
# ============================================================================

BEGIN {
    delete $ENV{PURL_REDIS_URL};
    $ENV{PURL_BROADCAST_MODE}  = 'local';
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';
    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';
}

my $dir = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_DIR}       = $dir;
$ENV{PURL_CONFIG_FILE}      = File::Spec->catfile($dir, 'settings.json');
$ENV{PURL_BROADCAST_SPOOL}  = File::Spec->catfile($dir, 'live-tail.spool');

require Purl::API::Server;

# Drain whatever another process wrote, giving the filesystem a few tries.
# Production arms this on a Mojo::IOLoop->recurring timer; the test calls it
# directly so it does not need a running event loop.
sub drain_until {
    my ($bc, $want, $tries) = @_;
    $tries //= 50;
    for (1 .. $tries) {
        $bc->drain;
        return 1 if $want->();
        select undef, undef, undef, 0.02;    ## no critic (ProhibitSleepViaSelect)
    }
    return 0;
}

# Publish from a genuinely separate process — the whole point is that a plain
# in-memory registry cannot cross this boundary.
sub publish_in_child {
    my ($bc, $channel, $payload) = @_;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    unless ($pid) {
        eval { $bc->publish($channel, $payload) };
        exit 0;
    }
    waitpid $pid, 0;
    return;
}

# ============================================
# 1. The default broadcaster must be fork-aware at all.
# ============================================
subtest 'default broadcaster survives prefork' => sub {
    my $bc = Purl::API::Server::_build_broadcaster();
    ok $bc, 'builder returned a broadcaster';
    ok $bc->does('Purl::Broadcast'), 'implements the broadcast role';
    ok $bc->can('drain'),
        'broadcaster can pick up what another worker published';
};

# ============================================
# 2. THE BUG: ingest in one worker, socket in another.
# ============================================
subtest 'a log published in another worker reaches this one' => sub {
    my $bc = Purl::API::Server::_build_broadcaster();
    my @received;
    $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });

    publish_in_child($bc, $bc->default_channel,
        [ { level => 'ERROR', message => 'from the ingest worker' } ]);

    ok drain_until($bc, sub { @received }), 'cross-worker message arrived';
    is scalar @received, 1, 'exactly one batch delivered';

    my $logs = decode_json($received[0]);
    is ref $logs, 'ARRAY', 'payload decodes to the log array';
    is $logs->[0]{message}, 'from the ingest worker', 'log body intact';
};

# ============================================
# 3. Same-worker delivery stays SYNCHRONOUS. Ingest and tail landing on one
#    worker is the case that accidentally worked before; it must not regress
#    into "wait for the next poll tick".
# ============================================
subtest 'same-worker publish is delivered immediately' => sub {
    my $bc = Purl::API::Server::_build_broadcaster();
    my @received;
    $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });

    $bc->publish($bc->default_channel, [ { message => 'same worker' } ]);
    is scalar @received, 1, 'delivered during publish(), no drain needed';

    # ...and draining afterwards must NOT hand it over a second time.
    $bc->drain for 1 .. 3;
    is scalar @received, 1, 'own publish is not replayed from the spool';
};

# ============================================
# 4. A socket that opens later tails; it does not get the backlog dumped
#    into it. logs.js prepends every frame to the visible list.
# ============================================
subtest 'a new subscriber does not replay the backlog' => sub {
    my $bc = Purl::API::Server::_build_broadcaster();
    publish_in_child($bc, $bc->default_channel, [ { message => 'ancient history' } ]);

    my @received;
    $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });
    $bc->drain for 1 .. 3;
    is scalar @received, 0, 'nothing published before subscribe is replayed';

    publish_in_child($bc, $bc->default_channel, [ { message => 'live line' } ]);
    ok drain_until($bc, sub { @received }), 'a later message still arrives';
    is scalar @received, 1, 'only the message published after subscribe';
};

# ============================================
# 5. Unsubscribe really stops cross-worker delivery too.
# ============================================
subtest 'unsubscribe stops cross-worker delivery' => sub {
    my $bc = Purl::API::Server::_build_broadcaster();
    my @received;
    my $id = $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });
    $bc->unsubscribe($id);

    publish_in_child($bc, $bc->default_channel, [ { message => 'after unsubscribe' } ]);
    $bc->drain for 1 .. 5;
    is scalar @received, 0, 'no delivery after unsubscribe';
};

# ============================================
# 6. Live tail is off almost all of the time. Ingest must not pay for it:
#    with nobody tailing anywhere in the container, publish() writes nothing.
# ============================================
subtest 'ingest does not touch the spool while nobody is tailing' => sub {
    require Purl::Broadcast::Prefork;
    my $spool = File::Spec->catfile($dir, 'idle.spool');
    my $bc = Purl::Broadcast::Prefork->new(spool_file => $spool);

    $bc->publish($bc->default_channel, [ { message => 'nobody is watching' } ]);

    ok !-e $spool, 'no spool file created by an ingest with no subscribers';

    # ...and it starts writing again as soon as a socket opens.
    $bc->subscribe($bc->default_channel, sub { });
    publish_in_child($bc, $bc->default_channel, [ { message => 'now watching' } ]);
    ok +(-s $spool), 'spool is written once a worker is tailing';
};

# ============================================
# 7. A broken spool must degrade, never take ingest down with it.
# ============================================
subtest 'an unusable spool degrades to local-only delivery' => sub {
    require Purl::Broadcast::Prefork;

    # A regular file cannot be a directory, so neither the spool nor its
    # parent can ever be created here. This is the read-only /app/config case.
    my $blocker = File::Spec->catfile($dir, 'blocker');
    open my $fh, '>', $blocker or die "open $blocker: $!";
    close $fh;

    my $bad = Purl::Broadcast::Prefork->new(
        spool_file => File::Spec->catfile($blocker, 'nested', 'spool'),
    );

    my @received;
    my $ok = eval {
        local $SIG{__WARN__} = sub { };
        $bad->subscribe($bad->default_channel, sub { push @received, $_[0] });
        $bad->publish($bad->default_channel, [ { message => 'still local' } ]);
        $bad->drain;
        1;
    };
    ok $ok, 'publish did not die on an unwritable spool';
    is scalar @received, 1, 'local subscribers still got the message';
};

done_testing;

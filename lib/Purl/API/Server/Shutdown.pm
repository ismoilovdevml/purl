package Purl::API::Server::Shutdown;
use strict;
use warnings;
use 5.024;

use Mojo::IOLoop ();

# ---------------------------------------------------------------------------
# Graceful shutdown of a prefork WORKER: flush its ingest buffer and close its
# WebSockets before the process goes away (#90).
#
# State is per-worker after fork, so every step here runs in each worker on
# its own exit:
#
#   1. IOLoop `finish` (graceful stop has begun: SIGQUIT from the manager,
#      SIGTERM/SIGINT to the worker, max_requests, missed heartbeat):
#      flush what is buffered and close WebSockets so the drain can finish.
#   2. END block (the worker's event loop has stopped and
#      Mojo::Server::Prefork::_spawn calls `exit 0`): a final flush of logs
#      that in-flight requests buffered DURING the drain, i.e. after step 1.
#      END runs before global destruction, while the storage's HTTP client
#      and JSON encoder still exist. DEMOLISH is not a substitute: at that
#      point those objects may already be freed and the batch is lost
#      ("Can't call method encode ... during global destruction").
#
# The worker also turns SIGTERM/SIGINT into a graceful stop (Mojo resets them
# to DEFAULT in the worker, which would kill it without running any of this).
#
# The END flush only runs in a process that claimed ownership in its event
# loop — a worker. The manager never runs the loop, and forked subprocesses
# (Mojo::IOLoop->subprocess) leave via POSIX::_exit, so a buffer copied across
# fork is never flushed twice.
# ---------------------------------------------------------------------------

my $current_storage;   # coderef returning the CURRENT storage (can be rebuilt)
my $log;
my $websockets = [];
my $owner_pid;         # pid of the worker whose buffer the END flush drains
my $hooks_installed;   # loop hooks are registered once per process

# Called in the manager before fork (build_prefork). A repeat call only
# updates what the hooks act on. %args:
#   storage     coderef returning the current storage object
#   websockets  arrayref of open WebSocket transactions
#   log         Mojo::Log
sub install {
    my (%args) = @_;
    $current_storage = $args{storage};
    $log             = $args{log};
    $websockets      = $args{websockets} // [];
    return if $hooks_installed++;

    my $loop = Mojo::IOLoop->singleton;

    # Queued before fork, so it runs first thing in each worker's own loop —
    # after Mojo::Server::Prefork has reset the worker's signal handlers.
    $loop->next_tick(sub {
        $owner_pid = $$;
        # Process-wide on purpose: these are the worker's own handlers.
        $SIG{TERM} = $SIG{INT} = sub { Mojo::IOLoop->stop_gracefully };  ## no critic (RequireLocalizedPunctuationVars)
    });

    $loop->on(finish => sub {
        flush_buffer('graceful stop');
        for my $tx (@$websockets) {
            eval { $tx->finish(1001 => 'Server shutting down'); 1 };
        }
    });

    return;
}

# Flush the current storage's buffer; errors are logged, never thrown (this
# runs from event and END hooks where a die would abort the shutdown).
sub flush_buffer {
    my ($why) = @_;
    my $storage = $current_storage ? $current_storage->() : undef;
    return 0 unless $storage && $storage->can('flush');

    my $n = eval { $storage->flush() };
    if (my $err = $@) {
        $log ? $log->error("Buffer flush failed ($why): $err")
             : warn "Buffer flush failed ($why): $err";
        return 0;
    }
    return $n // 0;
}

# Worker exit: the loop is stopped, global destruction has not started yet.
sub _flush_at_exit {
    return unless defined $owner_pid && $owner_pid == $$;
    local ($@, $!, $?);
    flush_buffer('worker exit');
    return;
}

END { _flush_at_exit() }

1;

__END__

=head1 NAME

Purl::API::Server::Shutdown - per-worker graceful shutdown: flush the ingest
buffer and close WebSockets before the worker exits (before global destruction).

=cut

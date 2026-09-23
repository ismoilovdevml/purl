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
# Ownership: the END flush and the signal handlers act only in the process
# that CLAIMED the worker role. The claim is a callback queued in the manager
# when it starts running (the server's `manager_start` event, see
# Purl::API::Server::Prefork) and inherited by every fork; it only takes
# effect in a process other than the manager, i.e. once it runs in a worker's
# own loop. A process that merely builds the server (tests) never arms it.
#
# Children forked FROM a worker (Mojo::IOLoop->subprocess, e.g. the alert
# check in Purl::API::Server::Cron) inherit the handlers but are not the
# owner: for them a TERM/INT takes its default action, and they leave via
# POSIX::_exit, so a buffer copied across fork is never flushed twice.
# ---------------------------------------------------------------------------

my $current_storage;   # coderef returning the CURRENT storage (can be rebuilt)
my $log;
my $websockets = [];
my $owner_pid;         # pid of the worker whose buffer the END flush drains
my $manager_pid;       # pid that armed the claim; never becomes the owner
my $hooks_installed;   # loop hooks are registered once per process

# Called before fork (build_prefork). A repeat call only updates what the
# hooks act on. %args:
#   storage     coderef returning the current storage object
#   websockets  arrayref of open WebSocket transactions
#   log         Mojo::Log
#   server      the Purl::API::Server::Prefork; the worker claim is armed on
#               its `manager_start` event
sub install {
    my (%args) = @_;
    $current_storage = $args{storage};
    $log             = $args{log};
    $websockets      = $args{websockets} // [];
    $args{server}->on(manager_start => sub { arm() }) if $args{server};
    return if $hooks_installed++;

    Mojo::IOLoop->singleton->on(finish => sub {
        flush_buffer('graceful stop');
        for my $tx (@$websockets) {
            eval { $tx->finish(1001 => 'Server shutting down'); 1 };
        }
    });

    return;
}

# Queue the worker claim in THIS (manager) process's loop. The manager itself
# never runs that loop while it manages workers, so the callback stays queued
# and every worker forked from it — including respawns — inherits it and runs
# it first thing, after Mojo::Server::Prefork has reset the worker's signals.
sub arm {
    $manager_pid = $$;
    Mojo::IOLoop->next_tick(\&_claim_worker);
    return;
}

sub _claim_worker {
    # Still the manager (its loop ran after all): not a worker, claim nothing.
    return if defined $manager_pid && $$ == $manager_pid;
    $owner_pid = $$;
    # Process-wide on purpose: these are the worker's own handlers.
    $SIG{TERM} = $SIG{INT} = \&_on_stop_signal;  ## no critic (RequireLocalizedPunctuationVars)
    return;
}

sub _on_stop_signal {
    my ($sig) = @_;
    return Mojo::IOLoop->stop_gracefully if defined $owner_pid && $$ == $owner_pid;

    # A child forked from the worker inherited this handler. Its loop is not
    # running, so stop_gracefully would swallow the signal and the child would
    # ignore TERM/INT. Take the default action instead. Not `local`: Perl
    # blocks $sig while this handler runs, so the re-raised signal is only
    # delivered after we return — by then the disposition must be DEFAULT.
    $SIG{$sig} = 'DEFAULT';  ## no critic (RequireLocalizedPunctuationVars)
    kill $sig, $$;
    return;
}

# The pid that claimed the worker role in this process tree, or undef.
sub owner_pid { return $owner_pid }

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

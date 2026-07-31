package Purl::Broadcast::Prefork;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json decode_json);
use Fcntl qw(:flock :seek);
use File::Basename qw(dirname);
use File::Path qw(make_path);

extends 'Purl::Broadcast::Local';

# ============================================================================
# Purl::Broadcast::Prefork - in-memory fan-out that ALSO crosses fork().
#
# Purl::Broadcast::Local keeps its subscriber list in a plain hashref, which is
# correct for one process and useless for the server we actually ship: run()
# builds the broadcaster and then forks `server.workers` (default 4) children.
# After the fork each worker owns a private copy of that hashref, so the worker
# holding a live-tail socket and the worker serving POST /api/logs are talking
# to two different registries and the socket receives nothing (#64).
#
# Redis (Purl::Broadcast::Redis) already solves this ACROSS replicas, but it is
# optional and unset in every default deployment, and the default chart runs a
# single replica - so the only boundary that has to be crossed out of the box
# is the fork boundary inside one pod. That needs no new service: the workers
# share a filesystem.
#
#   publish() -> deliver to this worker's subscribers IMMEDIATELY (unchanged
#                latency for the same-worker case)
#             -> append one line to a spool file on the config volume
#   drain()   -> read the lines other workers appended and fan them out here
#                (armed on a Mojo::IOLoop->recurring timer while at least one
#                subscriber exists; no timer, no polling, when nobody tails)
#
# Each line records the writer's PID so a worker never re-delivers its own
# publish. The spool is a bounded ring: it is truncated once it passes
# max_spool_bytes, and readers whose offset is past EOF restart from the front,
# which after a truncation is exactly the un-read remainder.
#
# Any filesystem failure degrades to local-only delivery. A read-only config
# volume must cost you cross-worker tail, never an ingest 5xx.
# ============================================================================

# Append-only spool shared by every worker in this container.
has 'spool_file' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_spool_file',
);

# How often a worker with subscribers looks for lines from its siblings.
has 'poll_interval' => (
    is      => 'ro',
    default => sub { 0.2 },
);

# Ring size. Live tail is a tail: old lines are worthless, so the spool is
# truncated rather than grown.
has 'max_spool_bytes' => (
    is      => 'ro',
    default => sub { 4 * 1024 * 1024 },
);

# Byte offset this worker has consumed. undef until the first subscriber, so a
# fresh socket tails from "now" instead of replaying the backlog.
has '_offset' => (
    is      => 'rw',
    default => sub { undef },
);

# Mojo::IOLoop recurring-timer id, while any subscriber exists.
has '_reader' => (
    is      => 'rw',
    default => sub { undef },
);

# Flipped to 0 by the first filesystem failure: from then on this worker is
# local-only and stops retrying on the ingest hot path.
has '_spool_ok' => (
    is      => 'rw',
    default => sub { 1 },
);

# How long after its last refresh the "somebody is tailing" marker still counts
# as live. Generous: the cost of being wrong is one skipped frame on a socket
# that opened microseconds ago, and a tail that has been open for a second is
# refreshed on every drain tick.
has 'marker_ttl' => (
    is      => 'ro',
    default => sub { 5 },
);

# Epoch of this worker's last marker refresh (throttled to 1/second).
has '_marker_touched' => (
    is      => 'rw',
    default => sub { 0 },
);

sub _build_spool_file {
    return $ENV{PURL_BROADCAST_SPOOL} if $ENV{PURL_BROADCAST_SPOOL};

    my $dir = $ENV{PURL_CONFIG_DIR}
        // dirname($ENV{PURL_CONFIG_FILE} // '/app/config/settings.json');

    return "$dir/live-tail.spool";
}

# ============================================================================
# Publish: local subscribers now, siblings via the spool.
# ============================================================================
sub publish {
    my ($self, $channel, $message) = @_;

    # Encode once: the spool line and the local callbacks get the same bytes.
    my $json = ref $message ? encode_json($message) : $message;

    $self->_append_spool($channel, $json);

    return $self->SUPER::publish($channel, $json);
}

# ============================================================================
# "Is anybody tailing?" marker.
#
# Without it every ingest request would append to the spool forever, even
# though live tail is an interactive feature that is off ~100% of the time.
# That is real write amplification on the config volume for nothing.
#
# So a worker that holds subscribers refreshes a marker file's mtime (at most
# once a second), and a publishing worker skips the spool entirely unless that
# marker is fresh. One stat() on the ingest path, served from the dentry cache.
# ============================================================================
sub _marker_file {
    my ($self) = @_;
    return $self->spool_file . '.active';
}

sub _touch_marker {
    my ($self) = @_;
    return 0 unless $self->_spool_ok;

    my $now = time;
    return 1 if $now - $self->_marker_touched < 1;
    $self->_marker_touched($now);

    my $path = $self->_marker_file;
    my $ok = eval {
        my $dir = dirname($path);
        make_path($dir) unless -d $dir;
        open my $fh, '>>', $path or die "open $path: $!\n";
        close $fh                or die "close $path: $!\n";
        utime undef, undef, $path;
        1;
    };

    return $ok ? 1 : 0;
}

sub _tail_active {
    my ($self) = @_;

    my $mtime = (stat $self->_marker_file)[9];
    return 0 unless defined $mtime;

    return (time - $mtime) <= $self->marker_ttl ? 1 : 0;
}

sub _append_spool {
    my ($self, $channel, $json) = @_;
    return 0 unless $self->_spool_ok;

    # Nobody in this container has a live-tail socket open — do not touch the
    # disk on the ingest hot path.
    return 0 unless $self->_tail_active;

    my $path = $self->spool_file;
    my $line = encode_json({ pid => $$, channel => $channel, payload => $json });

    my $ok = eval {
        my $dir = dirname($path);
        make_path($dir) unless -d $dir;

        open my $fh, '>>', $path or die "open $path: $!\n";
        flock $fh, LOCK_EX        or die "flock $path: $!\n";

        # O_APPEND already puts us at EOF, but seek AFTER taking the lock so
        # tell() reflects what other workers wrote while we were waiting.
        seek $fh, 0, SEEK_END or die "seek $path: $!\n";
        if (tell($fh) > $self->max_spool_bytes) {
            truncate $fh, 0 or die "truncate $path: $!\n";
            seek $fh, 0, SEEK_SET or die "seek $path: $!\n";
        }

        print {$fh} $line, "\n" or die "write $path: $!\n";
        close $fh               or die "close $path: $!\n";
        1;
    };

    unless ($ok) {
        # Once only: this runs on the ingest path and must not become a log
        # flood if the volume is read-only.
        warn "Broadcast::Prefork: spool disabled, live tail is worker-local ($@)";
        $self->_spool_ok(0);
        return 0;
    }

    return 1;
}

# ============================================================================
# Subscribe: same registry as Local, plus the reader timer.
# ============================================================================
sub subscribe {
    my ($self, $channel, $callback) = @_;

    my $id = $self->SUPER::subscribe($channel, $callback);
    $self->_start_reader;

    return $id;
}

sub unsubscribe {
    my ($self, $sub_id) = @_;

    my $result = $self->SUPER::unsubscribe($sub_id);
    $self->_stop_reader unless $self->_has_subscribers;

    return $result;
}

sub _has_subscribers {
    my ($self) = @_;

    for my $channel (keys %{ $self->_subscribers }) {
        return 1 if keys %{ $self->_subscribers->{$channel} };
    }

    return 0;
}

sub _start_reader {
    my ($self) = @_;

    # Announce to the other workers that this container is tailing, BEFORE
    # reading the offset — otherwise the first ingest after a socket opens
    # could still be skipped as "nobody is listening".
    $self->_touch_marker;

    # Tail from "now": anything already in the spool predates this socket.
    $self->_offset((-s $self->spool_file) // 0) unless defined $self->_offset;

    return 1 if defined $self->_reader;

    my $ok = eval {
        require Mojo::IOLoop;
        my $id = Mojo::IOLoop->recurring($self->poll_interval => sub { $self->drain });
        $self->_reader($id);
        1;
    };

    # No event loop (unit tests, CLI) simply means drain() is called by hand.
    return $ok ? 1 : 0;
}

sub _stop_reader {
    my ($self) = @_;
    return 0 unless defined $self->_reader;

    eval { Mojo::IOLoop->remove($self->_reader) };
    $self->_reader(undef);

    return 1;
}

# ============================================================================
# Drain: deliver what OTHER workers published. Returns the number of local
# callback invocations, so a caller can tell "nothing new" from "delivered".
# ============================================================================
sub drain {
    my ($self) = @_;

    # Every tick doubles as "yes, this container is still tailing".
    $self->_touch_marker if $self->_has_subscribers;

    my $path   = $self->spool_file;
    my $size   = (-s $path) // 0;
    my $offset = $self->_offset // 0;

    # The spool was truncated (ring wrapped): what is there now is all new.
    $offset = 0 if $size < $offset;
    return 0 if $size == $offset;

    my $delivered = 0;
    my $ok = eval {
        open my $fh, '<', $path or die "open $path: $!\n";
        seek $fh, $offset, SEEK_SET or die "seek $path: $!\n";

        while (defined(my $line = <$fh>)) {
            # No trailing newline means a writer is mid-append. Leave the
            # offset where it is and pick the line up on the next tick.
            last unless $line =~ s/\n\z//;
            $offset = tell $fh;

            my $record = eval { decode_json($line) };
            next unless ref $record eq 'HASH';
            next if ($record->{pid} // 0) == $$;   # our own publish, already delivered

            $delivered += $self->SUPER::publish(
                $record->{channel}, $record->{payload});
        }

        close $fh or die "close $path: $!\n";
        1;
    };

    unless ($ok) {
        warn "Broadcast::Prefork: spool read failed, live tail is worker-local ($@)";
        $self->_spool_ok(0);
        $self->_stop_reader;
        return 0;
    }

    $self->_offset($offset);

    return $delivered;
}

1;

__END__

=head1 NAME

Purl::Broadcast::Prefork - Cross-worker live-tail broadcast for a prefork server

=head1 SYNOPSIS

    my $bc = Purl::Broadcast::Prefork->new;

    # In the worker holding the WebSocket
    my $id = $bc->subscribe($bc->default_channel, sub { ... });

    # In the worker serving POST /api/logs
    $bc->publish($bc->default_channel, \@logs);

=head1 DESCRIPTION

Default broadcast backend. Behaves exactly like L<Purl::Broadcast::Local> for
subscribers in the same process, and additionally carries messages between the
prefork workers of one container through an append-only spool file.

Use L<Purl::Broadcast::Redis> instead when running more than one replica: a
spool file only reaches workers that share a filesystem.

=head1 CONFIGURATION

=over 4

=item * C<PURL_BROADCAST_SPOOL> - spool path. Defaults to
C<live-tail.spool> beside C<settings.json> (i.e. on the config volume).

=back

=head1 DEGRADATION

Any filesystem error disables the spool for that worker and logs one warning.
Delivery then falls back to same-worker only - never to a failed ingest.

=cut

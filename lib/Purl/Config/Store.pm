package Purl::Config::Store;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Fcntl qw(:flock);
use File::Spec;
use Time::HiRes ();
use namespace::clean;

# settings.json on disk: load, atomic save, the per-read freshness check that
# keeps prefork workers in sync, and the cross-process write lock.

requires qw(config_file _config _file_stamp _json);

# ============================================
# Cross-process freshness
# ============================================
#
# The server runs prefork: setup_routes() builds ONE Purl::Config in the
# manager and every worker inherits a private copy through fork(). A worker
# that creates a user mutates its own copy and writes settings.json; the other
# workers keep the pre-fork snapshot forever. That is why a freshly created
# user could not log in — the login request usually landed on a worker that had
# never heard of them.
#
# So the in-memory copy is treated as a cache of the file, not as the truth:
# every read checks whether settings.json changed underneath us and reloads.
# The check is one stat(2); the file is a few kB and read at most once per
# change.
sub _stat_stamp {
    my ($self) = @_;
    # Time::HiRes::stat gives a sub-second mtime. Plain stat(2) truncates to
    # whole seconds, so two saves inside the same second with the same byte
    # count would look identical and the second one would never be picked up.
    my @st = Time::HiRes::stat($self->config_file) or return '';
    # inode : size : mtime — a change to any of them means a new revision.
    return join(':', $st[1], $st[7], $st[9]);
}

sub _reload_if_changed {
    my ($self) = @_;
    return if $self->{_in_reload};

    my $stamp = $self->_stat_stamp;
    return if $stamp eq '' || $stamp eq $self->_file_stamp;

    local $self->{_in_reload} = 1;
    $self->load();
    return;
}

# Every read of the in-memory config goes through the accessor, so hooking it
# is what makes the freshness check impossible to forget in a new call site.
# Writes (and the reload itself) pass straight through.
around '_config' => sub {
    my ($orig, $self, @args) = @_;
    $self->_reload_if_changed unless @args;
    return $self->$orig(@args);
};

# ============================================
# Cross-process mutual exclusion
# ============================================
#
# The atomic write-then-rename in save() closes TORN READS. It does nothing
# about LOST UPDATES, which is the failure operators actually hit:
#
#   worker A: get_section('auth')  -> {users => {admin}}
#   worker B: get_section('auth')  -> {users => {admin}}
#   worker B: adds bob,   save()   -> {admin, bob}
#   worker A: adds alice, save()   -> {admin, alice}   # bob is gone
#
# Both workers believed they held current state — since every read re-checks
# the file, both were RIGHT at the moment they read. The read and the write
# have to be one critical section, which needs a real lock.
#
# The lock is an flock(2) on a sidecar file next to settings.json. It is never
# taken around a plain read: readers are already safe against a partial file
# because writers rename into place.
sub _lock_path {
    my ($self) = @_;
    return $self->config_file . '.lock';
}

# Take the exclusive lock WITHOUT blocking the process indefinitely.
#
# A plain flock(LOCK_EX) parks the whole Mojolicious worker: it is a single
# event loop, so every other in-flight request on that worker — including
# ingest — stops until the lock is released. Nothing bounds that wait.
#
# LOCK_NB plus a bounded retry keeps the failure mode small and known: after
# $LOCK_TIMEOUT we give up and the caller degrades to the SAME unlocked path it
# already takes when the lock file cannot be opened at all.
sub _acquire_lock {
    my ($self, $fh, $path) = @_;
    # The tunables are declared in Purl::Config; `perl -c` of this file alone
    # cannot see that and would warn "used only once".
    no warnings 'once';  ## no critic (ProhibitNoWarnings)

    my $deadline = Time::HiRes::time() + $Purl::Config::LOCK_TIMEOUT;
    while (1) {
        return 1 if flock($fh, LOCK_EX | LOCK_NB);

        # Only "somebody else holds it" is worth retrying. A real error
        # (no flock support on this filesystem) will never clear.
        unless ($!{EWOULDBLOCK} || $!{EAGAIN}) {
            warn "Cannot lock $path: $!";
            return 0;
        }

        if (Time::HiRes::time() >= $deadline) {
            warn "Timed out waiting for config lock $path after ${Purl::Config::LOCK_TIMEOUT}s; "
                . 'proceeding without it';
            return 0;
        }
        Time::HiRes::sleep($Purl::Config::LOCK_RETRY_MS / 1000);
    }
}

# Run $cb holding an exclusive lock, with the in-memory copy refreshed from
# disk FIRST so the callback modifies the newest revision and not our snapshot.
#
# Re-entrant: flock on a second descriptor would block against our own lock, so
# a nested call runs inline instead of deadlocking.
#
# If the lock cannot be taken (read-only directory, exotic filesystem) the
# callback still runs. Degrading to today's behaviour beats refusing to save.
sub _with_lock {
    my ($self, $cb) = @_;

    return $cb->() if $self->{_in_lock};

    my $path = $self->_lock_path;
    my $dir  = File::Spec->catpath((File::Spec->splitpath($path))[0, 1], '');
    if ($dir && !-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir) };
    }

    my $fh;
    unless (open $fh, '>>', $path) {
        warn "Cannot open config lock $path: $!";
        return $cb->();
    }
    unless ($self->_acquire_lock($fh, $path)) {
        close $fh;
        return $cb->();
    }

    local $self->{_in_lock} = 1;

    # Adopt whatever is on disk right now. Anything another worker committed
    # while we waited for the lock is part of the base we are about to modify.
    $self->_reload_if_changed;

    my @result = eval { $cb->() };
    my $err = $@;

    flock($fh, LOCK_UN);
    close $fh;

    die $err if $err;
    return wantarray ? @result : $result[0];
}

# Load config from file
sub load {
    my ($self) = @_;

    my $file = $self->config_file;

    # Stamp BEFORE reading: if the file changes while we read it, the stamp we
    # recorded is the older one and the next access reloads again.
    $self->_file_stamp($self->_stat_stamp);

    if (-f $file) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open $file: $!";
            local $/;
            my $json = <$fh>;
            close $fh;

            $self->_config($self->_json->decode($json));
        };
        if ($@) {
            # NEVER blank the in-memory config here. Since workers re-read on
            # every access, a decode failure is far more likely to be a
            # transient torn read than a genuinely corrupt file — and blanking
            # would drop every user and API key, then persist that
            # emptiness the next time anything called save().
            # Clearing the stamp makes the next access retry the read.
            warn "Failed to load config from $file: $@";
            $self->_file_stamp('');
        }
    }

    return $self->_config;
}

# Save config to file
sub save {
    my ($self) = @_;

    my $file = $self->config_file;
    my $dir = File::Spec->catpath((File::Spec->splitpath($file))[0, 1], '');

    # Ensure directory exists
    if ($dir && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    eval {
        # Serialize what the caller actually mutated. A freshness reload here
        # would silently discard their unsaved change and write someone else's
        # revision back while still reporting success.
        local $self->{_in_reload} = 1;
        my $payload = $self->_json->encode($self->_config);

        # Write-then-rename, NOT truncate-then-print. Every worker now re-reads
        # this file whenever its stat stamp moves, and truncation moves the
        # stamp instantly — so an in-place write guarantees that any worker
        # touching config in that window reads a partial file. rename(2) is
        # atomic on POSIX: readers see either the old file or the new one.
        my $tmp = "$file.tmp.$$";
        open my $fh, '>:encoding(UTF-8)', $tmp or die "Cannot write $tmp: $!";
        print $fh $payload or do { my $e = $!; close $fh; unlink $tmp; die "Cannot write $tmp: $e" };
        close $fh or do { my $e = $!; unlink $tmp; die "Cannot close $tmp: $e" };
        rename $tmp, $file or do { my $e = $!; unlink $tmp; die "Cannot rename $tmp to $file: $e" };
    };
    if ($@) {
        warn "Failed to save config to $file: $@";
        $self->{_last_save_error} = "$@";
        return 0;
    }

    # We are now the newest revision. Without this the next read would reload
    # what we just wrote and hand back a DIFFERENT hashref, detaching any
    # reference a caller still holds into the old structure.
    $self->_file_stamp($self->_stat_stamp);

    return 1;
}

1;

__END__

=head1 NAME

Purl::Config::Store - settings.json persistence for Purl::Config: load, atomic
write-then-rename save, reload-on-change across prefork workers and the flock
that makes read-modify-write one critical section.

=cut

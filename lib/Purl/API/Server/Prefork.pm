package Purl::API::Server::Prefork;
use strict;
use warnings;
use 5.024;

use Mojo::Base 'Mojo::Server::Prefork';

# Mojo::Server::Prefork treats SIGTERM/SIGINT to the manager as an IMMEDIATE
# stop: it SIGKILLs every worker, so nothing a worker holds in memory — its
# ingest buffer above all — survives. SIGTERM is what `docker stop`, systemd
# and most supervisors send by default, so for Purl every stop signal drains:
# TERM/INT behave exactly like QUIT (workers get QUIT, finish in-flight
# requests, flush their buffers, then exit). graceful_timeout still bounds how
# long a stuck worker may take before it is killed.
#
# Overrides the manager's private _term, which Mojo calls from two places:
#   - the INT/TERM/QUIT handlers run() installs, and
#   - _stopped(), when a worker dies before it ever became healthy ("stopped
#     too early, shutting down"). That shutdown now drains the remaining
#     workers too, instead of SIGKILLing them.
# t/server_prefork_shutdown.t (no ClickHouse, runs in CI) fails loudly if a
# Mojolicious upgrade removes or renames _term.
sub _term {
    my ($self) = @_;
    return $self->SUPER::_term(1);
}

# Emits `manager_start` in the manager right before it starts forking
# workers. Purl::API::Server::Shutdown arms its per-worker setup on it, so a
# process that only BUILDS a server (tests, build_prefork) is never touched.
sub run {
    my ($self, @args) = @_;
    $self->emit('manager_start');
    return $self->SUPER::run(@args);
}

1;

__END__

=head1 NAME

Purl::API::Server::Prefork - Mojo::Server::Prefork whose manager stops
gracefully on SIGTERM/SIGINT as well as SIGQUIT.

=head1 EVENTS

=head2 manager_start

Emitted in the manager process at the start of C<run>, before any worker is
forked.

=cut

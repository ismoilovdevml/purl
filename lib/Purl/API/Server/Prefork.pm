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
# Overrides the manager's private _term (the handler Mojo's run() installs for
# INT/TERM/QUIT). t/ingest_shutdown_flush.t sends a real SIGTERM and fails if
# a Mojolicious upgrade changes this hook.
sub _term {
    my ($self) = @_;
    return $self->SUPER::_term(1);
}

1;

__END__

=head1 NAME

Purl::API::Server::Prefork - Mojo::Server::Prefork whose manager stops
gracefully on SIGTERM/SIGINT as well as SIGQUIT.

=cut

package Purl::API::Controller::IngestBackpressure;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

requires 'storage';

# ============================================
# Ingest backpressure, shared by every endpoint that accepts logs
# (JSON/NDJSON, OTLP, syslog, K8s audit).
#
# The ingest buffer is bounded (buffer_max) and keeps a failed batch for retry
# (#115). While ClickHouse is down the buffer fills; from then on a new batch
# is refused with 503 + Retry-After instead of being accepted and dropped, so
# the shipper keeps it in its own (disk) buffer and retries. An endpoint that
# skipped this check would push the buffer past its cap and force the storage
# layer to drop the oldest rows.
#
# Returns 1 when it rendered the 503 — the caller MUST stop — else 0.
# NOTE: the buffer is per-process, so under prefork this is per worker.
# ============================================

sub reject_when_buffer_full {
    my ($self, $c, $incoming) = @_;

    my $storage = $self->storage;
    return 0 unless $storage && $storage->can('buffer_full');
    return 0 unless $storage->buffer_full($incoming // 0);

    $c->res->headers->header('Retry-After' => '1');
    $c->render(json => {
        status => 'error',
        error  => 'Ingest buffer full - backpressure, retry shortly',
    }, status => 503);
    return 1;
}

1;

__END__

=head1 NAME

Purl::API::Controller::IngestBackpressure - 503 + Retry-After when the ingest
buffer cannot take a batch; consumed by every log-ingest controller.

=cut

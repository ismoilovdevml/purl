package Purl::Storage::ClickHouse::Ingest;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape);
use Purl::Config;
use Purl::Util::Time qw(to_clickhouse_ts now_clickhouse);
use namespace::clean;

# Async insert buffer
has '_buffer' => (
    is      => 'rw',
    default => sub { [] },
);

has 'buffer_size' => (
    is      => 'ro',
    default => 5000,  # Soft threshold: flush is triggered when buffer reaches this
);

# Hard cap on the in-memory buffer. Beyond this the ingest layer must apply
# backpressure (503) rather than growing the buffer unbounded (OOM) or silently
# accepting logs it cannot store. ENV > settings.json > default (10000).
# NOTE: under prefork this cap is PER WORKER (each worker has its own buffer).
has 'buffer_max' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $v = eval { Purl::Config->new->get('ingest', 'buffer_max') };
        return (defined $v && $v =~ /^\d+$/ && $v > 0) ? $v + 0 : 10_000;
    },
);

# Durable ingest mode. When true, flush() waits for ClickHouse to confirm the
# async insert is persisted (wait_for_async_insert=1) so a 2xx to the client
# means the row is actually in ClickHouse. Default 0 keeps the legacy fast path.
# ENV (PURL_INGEST_DURABLE) > settings.json > default (0).
has 'durable' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $v = eval { Purl::Config->new->get('ingest', 'durable') };
        return (defined $v && $v) ? ($v ? 1 : 0) : 0;
    },
);

has 'flush_interval' => (
    is      => 'ro',
    default => 1,  # seconds
);

has '_last_flush' => (
    is      => 'rw',
    default => sub { time() },
);

# Current buffer depth (per-process / per-worker under prefork).
sub buffer_depth {
    my ($self) = @_;
    return scalar @{$self->_buffer};
}

# Backpressure check. Returns true when accepting $incoming more logs would push
# the buffer past buffer_max. The ingest layer uses this to return 503 instead
# of growing the buffer without bound. $incoming defaults to 0.
sub buffer_full {
    my ($self, $incoming) = @_;
    $incoming //= 0;
    return (scalar(@{$self->_buffer}) + $incoming) > $self->buffer_max;
}

# Insert single log
sub insert {
    my ($self, $log) = @_;

    push @{$self->_buffer}, $log;

    if (@{$self->_buffer} >= $self->buffer_size) {
        $self->flush();
    }

    return 1;
}

# Insert batch of logs
sub insert_batch {
    my ($self, $logs) = @_;

    return unless $logs && @$logs;

    push @{$self->_buffer}, @$logs;

    if (@{$self->_buffer} >= $self->buffer_size) {
        $self->flush();
    }

    return scalar @$logs;
}

# Flush buffer to ClickHouse with async insert.
#
# durable=0 (default): fire-and-forget async insert (wait_for_async_insert=0).
#   ClickHouse returns 200 before the batch is persisted — fast, at-most-once.
# durable=1: wait_for_async_insert=1 — the HTTP POST returns only once the row
#   is durable, so a successful flush() means the data is in ClickHouse.
#
# On failure the batch is put back at the head of the buffer in durable mode so
# the next flush retries it (at-least-once); the error is always re-thrown so
# the caller can surface a non-2xx to the client.
sub flush {
    my ($self) = @_;

    return 0 unless @{$self->_buffer};

    my @logs = @{$self->_buffer};
    $self->_buffer([]);
    $self->_last_flush(time());

    my $table = $self->database . '.' . $self->table;

    # Async-insert semantics adapt to durable mode (kept consistent with
    # _query_settings via _async_insert_settings).
    my $url = $self->_base_url . '/?' . $self->_auth_params;
    $url .= '&' . $self->_async_insert_settings;
    $url .= '&query=' . uri_escape("INSERT INTO $table FORMAT JSONEachRow");

    my @rows;
    my $bytes = 0;
    for my $log (@logs) {
        my $row = {
            timestamp      => $self->_format_timestamp($log->{timestamp}),
            level          => $log->{level} // 'INFO',
            service        => $log->{service} // 'unknown',
            host           => $log->{host} // 'localhost',
            message        => $log->{message} // '',
            raw            => $log->{raw} // '',
            meta           => $self->_json->encode($log->{meta} // {}),
            trace_id       => $log->{trace_id} // '',
            request_id     => $log->{request_id} // '',
            span_id        => $log->{span_id} // '',
            parent_span_id => $log->{parent_span_id} // '',
        };
        my $json = $self->_json->encode($row);
        $bytes += length($json);
        push @rows, $json;
    }

    my $body = join("\n", @rows);

    my $response = $self->_http->post($url, {
        content => $body,
        headers => {
            'Content-Type' => 'application/json',
            'X-ClickHouse-Async-Insert' => '1',
        },
    });

    unless ($response->{success}) {
        $self->_metrics->{errors_total}++;
        # In durable mode, do not lose the batch: return it to the buffer so the
        # next flush retries it. The error is re-thrown either way so the ingest
        # layer returns a non-2xx instead of a silent 200.
        if ($self->durable) {
            unshift @{$self->_buffer}, @logs;
        }
        die "ClickHouse insert error: $response->{status} - $response->{content}";
    }

    # Update metrics
    $self->_metrics->{inserts_total} += scalar @logs;
    $self->_metrics->{bytes_inserted} += $bytes;

    # Invalidate query cache so newly inserted logs are visible immediately
    $self->invalidate_logs_cache() if $self->can('invalidate_logs_cache');

    return scalar @logs;
}

# Check if flush is needed (time-based)
sub maybe_flush {
    my ($self) = @_;

    return 0 unless @{$self->_buffer};

    # Flush if buffer is full or interval exceeded
    if (@{$self->_buffer} >= $self->buffer_size ||
        (time() - $self->_last_flush) >= $self->flush_interval) {
        return $self->flush();
    }

    return 0;
}

# Format timestamp for ClickHouse DateTime64(3)
# Uses centralized Purl::Util::Time
sub _format_timestamp {
    my ($self, $ts) = @_;
    return to_clickhouse_ts($ts) || now_clickhouse();
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Ingest - buffered log ingest: the per-worker insert buffer,
backpressure (buffer_max), durable mode and flushing to ClickHouse.

=cut

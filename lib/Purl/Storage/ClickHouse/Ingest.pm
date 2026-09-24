package Purl::Storage::ClickHouse::Ingest;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape);
use Purl::Config;
use Purl::Config::EnvMap qw(bool_text);
use Purl::Util::Time qw(to_clickhouse_ts now_clickhouse);
use Purl::Util::Level qw(canonical_level);
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
        # bool_text: PURL_INGEST_DURABLE=false is a non-empty (true) string
        my $v = eval { Purl::Config->new->get('ingest', 'durable') };
        return bool_text($v) ? 1 : 0;
    },
);

# Called with ($count, $reason) whenever logs are dropped from the buffer, so
# the server can count them fleet-wide (purl_ingest_dropped_total). Optional.
has 'on_ingest_drop' => (
    is      => 'rw',
    default => sub { undef },
);

has 'flush_interval' => (
    is      => 'ro',
    default => 1,  # seconds
);

# True from a failed flush until the next successful one.
has '_flush_failing' => (
    is      => 'rw',
    default => 0,
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

# One canonical name per level: upper case (#105), synonyms folded (#110,
# WARNING -> WARN, CRIT -> FATAL; see Purl::Util::Level). Done here, not in each
# controller, because this is the one place every ingest path (JSON API, OTLP,
# syslog, K8s audit, Vector, _bulk) goes through. The hash is changed IN PLACE
# on purpose: the same hashref is broadcast to live tail, which must show what
# was stored.
sub _normalize_level {
    my ($log) = @_;
    return unless ref $log eq 'HASH';
    my $level = canonical_level($log->{level});
    $log->{level} = length $level ? $level : 'INFO';
    return;
}

# Insert single log
sub insert {
    my ($self, $log) = @_;
    $self->insert_batch([$log]);
    return 1;
}

# Insert batch of logs.
#
# The buffer never grows past buffer_max. Every ingest controller checks
# buffer_full() first and answers 503, so this cap is only reached by a caller
# that skipped that check; the OLDEST rows then make room, and are counted and
# logged as dropped — never silently.
#
# The size-triggered flush follows the ingest contract (#115):
#   durable — a failure is re-thrown, the request answers 503;
#   fast    — the batch stays in the buffer for the periodic retry, so the
#             logs this request already put there are still owned by Purl and
#             the request is not failed for them.
sub insert_batch {
    my ($self, $logs) = @_;

    return unless $logs && @$logs;

    _normalize_level($_) for @$logs;
    push @{$self->_buffer}, @$logs;

    my $over = @{$self->_buffer} - $self->buffer_max;
    if ($over > 0) {
        splice @{$self->_buffer}, 0, $over;
        $self->_record_drop($over, 'ingest buffer over buffer_max');
    }

    # While ClickHouse is failing, retry at most once per flush_interval —
    # not once per inserted log (the controller inserts row by row).
    my $backing_off = $self->_flush_failing
        && (time() - $self->_last_flush) < $self->flush_interval;

    if (@{$self->_buffer} >= $self->buffer_size && !$backing_off) {
        if ($self->durable) {
            $self->flush();
        }
        elsif (!eval { $self->flush(); 1 }) {
            warn "Ingest flush failed, batch kept for retry: $@";
        }
    }

    return scalar @$logs;
}

sub _record_drop {
    my ($self, $count, $reason) = @_;
    $self->_metrics->{ingest_dropped_total} += $count;
    my $hook = $self->on_ingest_drop;
    return if $hook && eval { $hook->($count, $reason); 1 };
    warn "Ingest DROPPED $count log(s): $reason\n";   # no hook (or it failed)
    return;
}

# Flush buffer to ClickHouse with async insert.
#
# durable=0 (default): fire-and-forget async insert (wait_for_async_insert=0).
#   The client got its 200 when the log entered the buffer.
# durable=1: wait_for_async_insert=1 — the HTTP POST returns only once the row
#   is durable, so a successful flush() means the data is in ClickHouse.
#
# On failure the batch goes back to the head of the buffer in BOTH modes, so the
# next flush retries it (#115: fast mode used to drop it, after the client had
# its 200). The buffer stays bounded by buffer_max, and ingest answers 503 once
# it is full, so an outage turns into backpressure on the shippers — which
# retry non-2xx from their own disk buffers — instead of lost logs. The error
# is re-thrown so the caller can log it / surface a non-2xx.
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
            meta           => $self->_encode_json_column($log->{meta} // {}),  # text, not bytes (#113)
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
        $self->_metrics->{ingest_flush_failures}++;
        unshift @{$self->_buffer}, @logs;
        $self->_flush_failing(1);
        die "ClickHouse insert error: $response->{status} - $response->{content}";
    }

    $self->_flush_failing(0);

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

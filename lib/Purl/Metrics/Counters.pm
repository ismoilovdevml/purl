package Purl::Metrics::Counters;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

# ============================================================================
# Purl::Metrics::Counters
#
# Prometheus counters that survive prefork.
#
# THE PROBLEM: Server.pm's %metrics hash is created per process. With N
# workers, a scrape hits ONE worker and therefore sees roughly 1/N of reality
# — and a different 1/N on every scrape, so rate() over the series is noise.
# Alert rules built on that are worse than no alert rules.
#
# THE FIX: route the counters through Purl::Store::Counter, the SAME shared
# store that already backs rate limiting and login lockout. With Redis
# configured every worker and every replica increments one atomic counter, so
# any worker can serve a correct scrape. Without Redis it degrades to
# per-worker in-memory counting, which is exactly the status quo — no worse.
#
# LABEL CARDINALITY: the store exposes INCR/INCRBY/GET on known keys, not key
# enumeration, so a scrape can only read back labels it can NAME. Methods and
# status codes are therefore drawn from fixed allowlists, with anything else
# folded into an `other` bucket. This keeps `status=~"5.."` working for every
# status Purl actually emits while making the key space finite and scrapeable.
# ============================================================================

# The shared counter store (Purl::Store::Counter).
has 'store' => (is => 'ro', required => 1);

# Counters are monotonic, but an abandoned Redis key must not live forever.
# The TTL is a fixed window: values reset at most once per window, which
# Prometheus handles natively (counter reset detection).
has 'ttl' => (
    is      => 'ro',
    default => sub {
        my $ttl = $ENV{PURL_METRICS_TTL};
        return ($ttl && $ttl =~ /^\d+$/ && $ttl > 0) ? $ttl : 604_800;  # 7 days
    },
);

has 'prefix' => (is => 'ro', default => sub { 'purl:metrics:' });

my @METHODS = qw(GET POST PUT PATCH DELETE HEAD OPTIONS other);
my %IS_METHOD = map { $_ => 1 } @METHODS;

# Every status code Purl renders anywhere, plus an `other` catch-all.
my @STATUSES = qw(200 201 202 204 206 301 302 304 400 401 403 404 405 409 413
                  422 429 500 502 503 other);
my %IS_STATUS = map { $_ => 1 } @STATUSES;

sub _key { my ($self, $name) = @_; return $self->prefix . $name }

sub _norm_method {
    my ($method) = @_;
    $method = uc($method // '');
    return $IS_METHOD{$method} ? $method : 'other';
}

sub _norm_status {
    my ($status) = @_;
    $status //= '';
    return $IS_STATUS{$status} ? $status : 'other';
}

# ----------------------------------------------------------------------------
# Recording
# ----------------------------------------------------------------------------

# One request: bumps the labelled request counter, the error counter for 4xx/5xx,
# and the latency sum/count. Never dies — a metrics failure must not fail a
# request, so every store call is wrapped.
sub record_request {
    my ($self, %args) = @_;

    my $method = _norm_method($args{method});
    my $status = _norm_status($args{status});

    eval {
        $self->store->incr($self->_key("http_requests:$method:$status"), $self->ttl);
        $self->store->incr($self->_key('errors_total'), $self->ttl)
            if ($args{status} // 0) >= 400;

        # Latency is accumulated in whole milliseconds because the store is
        # integer-only (Redis INCRBY); the exporter divides by 1000 to publish
        # seconds, which is the Prometheus base unit.
        my $ms = int(($args{duration_ms} // 0) + 0.5);
        $self->store->incr_by($self->_key('query_latency_ms_sum'), $ms, $self->ttl);
        $self->store->incr($self->_key('query_latency_count'), $self->ttl);
        1;
    } or return 0;

    return 1;
}

sub record_ingest_bytes {
    my ($self, $bytes) = @_;
    return 0 unless $bytes && $bytes > 0;
    eval { $self->store->incr_by($self->_key('ingest_bytes_total'), $bytes, $self->ttl); 1 }
        or return 0;
    return 1;
}

# Logs Purl accepted and then had to drop (ingest buffer overflow, #115).
sub record_ingest_dropped {
    my ($self, $count) = @_;
    return 0 unless $count && $count > 0;
    eval { $self->store->incr_by($self->_key('ingest_dropped_total'), $count, $self->ttl); 1 }
        or return 0;
    return 1;
}

# ----------------------------------------------------------------------------
# Reading
# ----------------------------------------------------------------------------

# Everything the exporter needs, in one structure. Reads only keys this module
# can name (see LABEL CARDINALITY above).
sub snapshot {
    my ($self) = @_;

    my %requests;
    for my $method (@METHODS) {
        for my $status (@STATUSES) {
            my $count = eval { $self->store->get($self->_key("http_requests:$method:$status")) } // 0;
            $requests{$method}{$status} = $count if $count;
        }
    }

    return {
        requests           => \%requests,
        errors_total       => eval { $self->store->get($self->_key('errors_total')) } // 0,
        ingest_bytes_total => eval { $self->store->get($self->_key('ingest_bytes_total')) } // 0,
        ingest_dropped_total => eval { $self->store->get($self->_key('ingest_dropped_total')) } // 0,
        latency_ms_sum     => eval { $self->store->get($self->_key('query_latency_ms_sum')) } // 0,
        latency_count      => eval { $self->store->get($self->_key('query_latency_count')) } // 0,
        shared             => eval { $self->store->is_shared } // 0,
    };
}

sub methods  { return [@METHODS] }
sub statuses { return [@STATUSES] }

1;

__END__

=head1 NAME

Purl::Metrics::Counters - Prefork-safe Prometheus counters

=head1 SYNOPSIS

    my $counters = Purl::Metrics::Counters->new(store => $counter_store);

    $counters->record_request(method => 'POST', status => 201, duration_ms => 12.4);
    $counters->record_ingest_bytes(4096);
    $counters->record_ingest_dropped(12);

    my $snapshot = $counters->snapshot;

=head1 DESCRIPTION

Wraps L<Purl::Store::Counter> so request/error/latency/ingest counters are
shared across prefork workers and replicas instead of being per-process. With
no Redis configured the store degrades to per-worker memory and these counters
degrade with it — same accuracy as before, never worse.

=head1 ENVIRONMENT

    PURL_METRICS_TTL - counter key lifetime in seconds (default 604800 = 7d)

=cut

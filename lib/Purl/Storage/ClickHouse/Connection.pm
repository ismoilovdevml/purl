package Purl::Storage::ClickHouse::Connection;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use HTTP::Tiny;
use JSON::XS ();
use URI::Escape qw(uri_escape);
use Time::HiRes qw(time);
use namespace::clean;

# Connection pool with keep-alive
has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        HTTP::Tiny->new(
            timeout      => 60,
            keep_alive   => 1,
            max_redirect => 0,
            agent        => 'Purl/1.0',
        )
    },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical->allow_nonref },
);

# Metrics
has '_metrics' => (
    is      => 'rw',
    default => sub { {
        queries_total     => 0,
        queries_cached    => 0,
        inserts_total     => 0,
        bytes_inserted    => 0,
        query_time_total  => 0,
        errors_total      => 0,
    } },
);

sub _base_url {
    my ($self) = @_;
    return sprintf('http://%s:%d', $self->host, $self->port);
}

sub _auth_params {
    my ($self) = @_;
    my @params;
    push @params, 'user=' . uri_escape($self->username) if $self->username;
    push @params, 'password=' . uri_escape($self->password) if $self->password;
    push @params, 'database=' . uri_escape($self->database);
    return join('&', @params);
}

# Async-insert settings, applied consistently everywhere an INSERT is issued.
# durable=1 => wait_for_async_insert=1 (HTTP returns only once the row is
# persisted). durable=0 => legacy fire-and-forget fast path.
sub _async_insert_settings {
    my ($self) = @_;
    my $wait = $self->durable ? 1 : 0;
    return "async_insert=1&wait_for_async_insert=$wait";
}

# ClickHouse performance settings.
#
# sync => 1 makes the statement read-after-write consistent:
#   async_insert=0   — the INSERT is not parked in ClickHouse's async buffer
#   mutations_sync=1 — ALTER ... UPDATE/DELETE is applied before we return
#
# Log ingest batches thousands of rows/s and trades visibility latency for
# throughput. CRUD statements (alerts, saved searches, dashboards, pipelines,
# agents) write one row at a time and are read back immediately by the UI, so
# for them the async buffer and background mutations are pure downside: the row
# is invisible — or a deleted row still visible — for seconds after a 200 OK.
sub _query_settings {
    my ($self, %opts) = @_;
    my @settings = (
        'max_execution_time=' . $self->max_execution_time,
        'max_rows_to_read=' . $self->max_rows_to_read,
        'optimize_read_in_order=1',
        'load_balancing=nearest_hostname',
        'prefer_localhost_replica=1',
        $opts{sync} ? 'async_insert=0&mutations_sync=1' : $self->_async_insert_settings,
    );
    return join('&', @settings);
}

# Build the query URL. %opts:
#   no_settings => 1        omit the standard performance/safety settings
#   settings    => 'a=1&b'  use THESE settings instead of the standard ones
#                           (backup export needs its own timeout and an
#                           unbounded row cap without disabling everything)
#   format      => 'CSV'    default_format
#   params      => {}       bind parameters
#   sync        => 1        disable async insert (read-after-write CRUD)
sub _query_url {
    my ($self, %opts) = @_;

    my $url = $self->_base_url . '/?' . $self->_auth_params;

    if (defined $opts{settings}) {
        $url .= '&' . $opts{settings};
    }
    elsif (!$opts{no_settings}) {
        $url .= '&' . $self->_query_settings(sync => $opts{sync});
    }

    $url .= '&default_format=' . $opts{format} if $opts{format};

    if (my $params = $opts{params}) {
        for my $key (keys %$params) {
            $url .= '&param_' . uri_escape($key) . '=' . uri_escape($params->{$key});
        }
    }

    return $url;
}

sub _query {
    my ($self, $sql, %opts) = @_;

    $self->_circuit_guard;

    my $start = time();
    my $url   = $self->_query_url(%opts);

    my $response = $self->_http->post($url, {
        content => $sql,
        headers => {
            'Content-Type' => 'text/plain',
            'X-ClickHouse-Format' => $opts{format} // 'TabSeparated',
        },
    });

    $self->_circuit_record($response->{success}, time() - $start);

    unless ($response->{success}) {
        die "ClickHouse error: $response->{status} - $response->{content}";
    }

    return $response->{content};
}

# Exact rows written by the last statement, from ClickHouse's summary header.
# Returns undef when the server did not send one (older versions), so callers
# can fall back rather than silently reporting 0.
sub _written_rows {
    my ($self, $response) = @_;
    my $summary = $response->{headers}{'x-clickhouse-summary'} // return undef;
    $summary = $summary->[0] if ref $summary eq 'ARRAY';
    my ($rows) = $summary =~ /"written_rows"\s*:\s*"?(\d+)/;
    return $rows;
}

# Run a query and stream the response STRAIGHT TO A FILE.
#
# This exists because a table export must never be materialised in a Perl
# scalar: `SELECT * FROM logs` on a real deployment is tens of gigabytes and
# slurping it OOM-kills the worker (which is exactly what backups used to do).
# Memory here is one HTTP chunk, whatever the table size.
#
# Returns the number of bytes written.
sub _query_to_file {
    my ($self, $sql, $file_path, %opts) = @_;

    $self->_circuit_guard;

    my $start = time();
    my $url   = $self->_query_url(%opts);

    open my $fh, '>:raw', $file_path or die "Cannot write $file_path: $!";

    my $bytes = 0;
    my $response = eval {
        $self->_http->request('POST', $url, {
            content => $sql,
            headers => {
                'Content-Type' => 'text/plain',
                'X-ClickHouse-Format' => $opts{format} // 'TabSeparated',
            },
            # HTTP::Tiny only routes 2xx bodies through data_callback; an error
            # response still lands in $response->{content}, so failures keep
            # their diagnostics instead of being written into the export.
            data_callback => sub {
                $bytes += length $_[0];
                print {$fh} $_[0] or die "Write to $file_path failed: $!";
            },
        });
    };
    my $err = $@;
    close $fh;

    if ($err) {
        unlink $file_path;
        $self->_circuit_record(0, time() - $start);
        die $err;
    }

    $self->_circuit_record($response->{success}, time() - $start);

    unless ($response->{success}) {
        unlink $file_path;
        die "ClickHouse error: $response->{status} - $response->{content}";
    }

    return $bytes;
}

# POST a file as the body of a statement (INSERT ... FORMAT CSVWithNames).
# Streams from disk for the same reason as _query_to_file — a restore must not
# be bounded by RAM.
sub _post_file {
    my ($self, $sql, $file_path, %opts) = @_;

    $self->_circuit_guard;
    die "File not found: $file_path" unless -f $file_path;

    my $start = time();
    my $url   = $self->_query_url(%opts) . '&query=' . uri_escape($sql);

    open my $fh, '<:raw', $file_path or die "Cannot read $file_path: $!";

    my $response = eval {
        $self->_http->request('POST', $url, {
            content => sub {
                my $buffer = '';
                my $read = read $fh, $buffer, 262_144;
                return defined $read && $read > 0 ? $buffer : '';
            },
            headers => {
                'Content-Type'   => 'text/csv',
                'Content-Length' => (-s $file_path),
            },
        });
    };
    my $err = $@;
    close $fh;

    if ($err) {
        $self->_circuit_record(0, time() - $start);
        die $err;
    }

    $self->_circuit_record($response->{success}, time() - $start);

    unless ($response->{success}) {
        die "ClickHouse error: $response->{status} - $response->{content}";
    }

    # The full response, not just the body: an INSERT answers with an empty
    # body but carries X-ClickHouse-Summary, the only exact row count a
    # restore can get.
    return $response;
}

# Note: Cache management methods are provided by Purl::Storage::ClickHouse::Cache role

sub _query_json {
    my ($self, $sql, %opts) = @_;

    # Check cache for read queries
    my $cache_key;
    my $is_select = $sql =~ /^\s*SELECT/i;
    # Add params to cache key to ensure uniqueness
    if ($is_select && !$opts{no_cache}) {
        $cache_key = $self->_get_cache_key($sql, $opts{params});
        if (my $cached = $self->_get_cached($cache_key)) {
            return $cached;
        }
    }

    my $result = $self->_query($sql, format => 'JSONEachRow', params => $opts{params});

    return [] unless $result && length($result);

    my @rows;
    for my $line (split /\n/, $result) {
        next unless $line =~ /\S/;
        push @rows, $self->_json->decode($line);
    }

    # Cache the result
    if ($cache_key) {
        $self->_set_cached($cache_key, \@rows);
    }

    return \@rows;
}

# ============================================
# CRUD (metadata) statements
# ============================================
#
# Alerts, saved searches, dashboards, pipelines, agents: single rows, written
# and read back immediately by the UI. Both halves of read-after-write have to
# be forced, and BOTH were broken:
#
#   write — async_insert / background mutations meant a 200 OK did not mean
#           "visible to the next SELECT";
#   read  — _query_json caches every SELECT for cache_ttl (5s), and under
#           prefork each worker has its OWN cache, so a create followed by a
#           list flip-flopped depending on which worker answered.
#
# Invalidating the cache on write cannot fix the read side: the writing worker
# is not the worker that will serve the next list. These rows are a handful per
# deployment, so not caching them at all is both correct and free.

sub _crud_write {
    my ($self, $sql, %opts) = @_;
    return $self->_query($sql, %opts, sync => 1);
}

sub _crud_read {
    my ($self, $sql, %opts) = @_;
    return $self->_query_json($sql, %opts, no_cache => 1);
}

# Check connection
sub ping {
    my ($self) = @_;

    eval {
        $self->_query('SELECT 1');
    };

    return $@ ? 0 : 1;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Connection - HTTP transport to ClickHouse: URL/settings building, query execution
(plain, JSON, streamed to/from files), read-after-write CRUD helpers and ping.

Every round-trip goes through the circuit breaker from
L<Purl::Storage::ClickHouse::CircuitBreaker>; read caching comes from
L<Purl::Storage::ClickHouse::Cache>.

=cut

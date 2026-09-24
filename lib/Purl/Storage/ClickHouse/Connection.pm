package Purl::Storage::ClickHouse::Connection;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use HTTP::Tiny;
use JSON::XS ();
use URI::Escape qw(uri_escape uri_escape_utf8);
use Encode qw(encode_utf8);
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

# Encoding contract (#113): SQL text and bind parameters are Perl CHARACTER
# strings (what Mojolicious hands us for a query string or a JSON body). They
# are encoded to UTF-8 here, once, on the way to ClickHouse — never by callers.
# Passing characters above U+00FF straight to HTTP::Tiny / uri_escape dies with
# "Wide character", and passing U+0080..U+00FF sends Latin-1 bytes that match
# nothing stored as UTF-8.

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
            $url .= '&param_' . uri_escape_utf8($key) . '=' . uri_escape_utf8($params->{$key} // '');
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
        content => encode_utf8($sql),
        headers => {
            'Content-Type' => 'text/plain',
            'X-ClickHouse-Format' => $opts{format} // 'TabSeparated',
        },
    });

    my $failure = $response->{success} ? undef
        : "ClickHouse error: $response->{status} - $response->{content}";
    $self->_circuit_record($response->{success}, time() - $start, $failure);

    die $failure if defined $failure;

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
            content => encode_utf8($sql),
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
        $self->_circuit_record(0, time() - $start, $err);
        die $err;
    }

    my $failure = $response->{success} ? undef
        : "ClickHouse error: $response->{status} - $response->{content}";
    $self->_circuit_record($response->{success}, time() - $start, $failure);

    if (defined $failure) {
        unlink $file_path;
        die $failure;
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
    my $url   = $self->_query_url(%opts) . '&query=' . uri_escape_utf8($sql);

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
        $self->_circuit_record(0, time() - $start, $err);
        die $err;
    }

    my $failure = $response->{success} ? undef
        : "ClickHouse error: $response->{status} - $response->{content}";
    $self->_circuit_record($response->{success}, time() - $start, $failure);

    die $failure if defined $failure;

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

# 0/1 for a UInt8 flag on update: the new value when the request sends one,
# else the stored one. Stored flags read back as \1 / \0 (JSON booleans), and a
# reference is always true — unwrapped, or every update switched them ON.
sub _crud_flag {
    my ($self, $data, $existing, $key) = @_;
    my $v = exists $data->{$key} ? $data->{$key} : $existing->{$key};
    $v = $$v if ref $v eq 'SCALAR';
    return $v ? 1 : 0;
}

# Update a ReplacingMergeTree CRUD row (dashboards, pipelines) by inserting
# its next version. %$values maps column => SQL literal (already quoted).
#
# created_at is copied from the stored row BY CLICKHOUSE (INSERT ... SELECT),
# never round-tripped through Perl: the API shows it as '...T..:..:..Z', which
# a DateTime column refuses (#114), and a client-supplied value must not be
# able to rewrite it anyway. Nothing is inserted for an unknown id.
sub _insert_crud_version {
    my ($self, $table, $id, $values) = @_;
    my @cols = sort keys %$values;
    # Column names are interpolated into SQL: identifiers only.
    /^\w+\z/ or die "Invalid column name: $_\n" for @cols;
    my $sql = "INSERT INTO $table (id, " . join(', ', @cols) . ', created_at, updated_at) '
        . 'SELECT id, ' . join(', ', @$values{@cols}) . ', created_at, now() '
        . "FROM $table FINAL WHERE toString(id) = " . $self->_quote_string($id) . ' LIMIT 1';
    return $self->_crud_write($sql);
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

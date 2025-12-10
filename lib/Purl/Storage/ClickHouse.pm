package Purl::Storage::ClickHouse;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();
use URI::Escape qw(uri_escape);
use Time::Piece;

has 'host' => (
    is      => 'ro',
    default => 'localhost',
);

has 'port' => (
    is      => 'ro',
    default => 8123,
);

has 'database' => (
    is      => 'ro',
    default => 'purl',
);

has 'username' => (
    is      => 'ro',
    default => 'default',
);

has 'password' => (
    is      => 'ro',
    default => '',
);

has 'table' => (
    is      => 'ro',
    default => 'logs',
);

has 'retention_days' => (
    is      => 'ro',
    default => 30,
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { HTTP::Tiny->new(timeout => 30) },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical },
);

has '_buffer' => (
    is      => 'rw',
    default => sub { [] },
);

has 'buffer_size' => (
    is      => 'ro',
    default => 1000,
);

sub BUILD {
    my ($self) = @_;
    $self->_init_schema();
}

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

sub _query {
    my ($self, $sql, %opts) = @_;

    my $url = $self->_base_url . '/?' . $self->_auth_params;

    if ($opts{format}) {
        $url .= '&default_format=' . $opts{format};
    }

    my $response = $self->_http->post($url, {
        content => $sql,
        headers => {
            'Content-Type' => 'text/plain',
        },
    });

    unless ($response->{success}) {
        die "ClickHouse error: $response->{status} - $response->{content}";
    }

    return $response->{content};
}

sub _query_json {
    my ($self, $sql) = @_;

    my $result = $self->_query($sql, format => 'JSONEachRow');

    return [] unless $result && length($result);

    my @rows;
    for my $line (split /\n/, $result) {
        next unless $line =~ /\S/;
        push @rows, $self->_json->decode($line);
    }

    return \@rows;
}

sub _init_schema {
    my ($self) = @_;

    # Create database first (without database in URL)
    my $url = sprintf('http://%s:%d/?user=%s',
        $self->host, $self->port, uri_escape($self->username));
    $url .= '&password=' . uri_escape($self->password) if $self->password;

    my $response = $self->_http->post($url, {
        content => "CREATE DATABASE IF NOT EXISTS " . $self->database,
        headers => { 'Content-Type' => 'text/plain' },
    });

    unless ($response->{success}) {
        die "ClickHouse error creating database: $response->{status} - $response->{content}";
    }

    # Create logs table with MergeTree engine
    my $table = $self->database . '.' . $self->table;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS $table (
            id UUID DEFAULT generateUUIDv4(),
            timestamp DateTime64(3),
            level LowCardinality(String),
            service LowCardinality(String),
            host LowCardinality(String),
            message String,
            raw String,
            meta String,

            INDEX idx_level level TYPE set(100) GRANULARITY 4,
            INDEX idx_service service TYPE set(1000) GRANULARITY 4,
            INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4
        )
        ENGINE = MergeTree()
        PARTITION BY toYYYYMMDD(timestamp)
        ORDER BY (timestamp, level, service)
        TTL toDateTime(timestamp) + INTERVAL $self->{retention_days} DAY
        SETTINGS index_granularity = 8192
    });

    # Create materialized view for level stats
    $self->_query(qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS ${table}_level_stats
        ENGINE = SummingMergeTree()
        ORDER BY (date, level)
        AS SELECT
            toDate(timestamp) as date,
            level,
            count() as count
        FROM $table
        GROUP BY date, level
    });

    # Create materialized view for service stats
    $self->_query(qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS ${table}_service_stats
        ENGINE = SummingMergeTree()
        ORDER BY (date, service)
        AS SELECT
            toDate(timestamp) as date,
            service,
            count() as count
        FROM $table
        GROUP BY date, service
    });
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

# Flush buffer to ClickHouse
sub flush {
    my ($self) = @_;

    return unless @{$self->_buffer};

    my @logs = @{$self->_buffer};
    $self->_buffer([]);

    my $table = $self->database . '.' . $self->table;

    # Build INSERT query with JSONEachRow format
    my $url = $self->_base_url . '/?' . $self->_auth_params;
    $url .= '&query=' . uri_escape("INSERT INTO $table FORMAT JSONEachRow");

    my @rows;
    for my $log (@logs) {
        my $row = {
            timestamp => $self->_format_timestamp($log->{timestamp}),
            level     => $log->{level} // 'INFO',
            service   => $log->{service} // 'unknown',
            host      => $log->{host} // 'localhost',
            message   => $log->{message} // '',
            raw       => $log->{raw} // '',
            meta      => $self->_json->encode($log->{meta} // {}),
        };
        push @rows, $self->_json->encode($row);
    }

    my $body = join("\n", @rows);

    my $response = $self->_http->post($url, {
        content => $body,
        headers => { 'Content-Type' => 'application/json' },
    });

    unless ($response->{success}) {
        die "ClickHouse insert error: $response->{status} - $response->{content}";
    }

    return scalar @logs;
}

# Format timestamp for ClickHouse DateTime64(3)
# Required format: YYYY-MM-DD HH:MM:SS.mmm (space, not T)
sub _format_timestamp {
    my ($self, $ts) = @_;

    if ($ts) {
        # Replace T with space for ClickHouse
        $ts =~ s/T/ /;
        # Remove Z suffix if present
        $ts =~ s/Z$//;
        # Ensure milliseconds exist
        $ts .= '.000' unless $ts =~ /\.\d{3}$/;
        return $ts if $ts =~ /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}$/;
    }

    # Default to now with milliseconds
    my $t = Time::Piece->new;
    return sprintf('%s.000', $t->strftime('%Y-%m-%d %H:%M:%S'));
}

# Convert ISO timestamp (from API) to ClickHouse format for queries
sub _convert_to_clickhouse_ts {
    my ($self, $ts) = @_;
    return '' unless $ts;

    # Replace T with space
    $ts =~ s/T/ /;
    # Remove Z suffix
    $ts =~ s/Z$//;
    # Add milliseconds if missing
    $ts .= '.000' unless $ts =~ /\.\d+$/;

    return $ts;
}

# Search logs
sub search {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my @where;
    my @values;

    # Time range - convert ISO format to ClickHouse format
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        push @where, "timestamp >= '$from_ts'";
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        push @where, "timestamp <= '$to_ts'";
    }

    # Level filter
    if ($params{level}) {
        if (ref $params{level} eq 'ARRAY') {
            my $levels = join(',', map { "'$_'" } @{$params{level}});
            push @where, "level IN ($levels)";
        } else {
            push @where, "level = '$params{level}'";
        }
    }

    # Service filter
    if ($params{service}) {
        if ($params{service} =~ /\*/) {
            my $pattern = $params{service};
            $pattern =~ s/\*/%/g;
            push @where, "service LIKE '$pattern'";
        } else {
            push @where, "service = '$params{service}'";
        }
    }

    # Host filter
    if ($params{host}) {
        push @where, "host = '$params{host}'";
    }

    # Full-text search in message
    if ($params{query}) {
        my $escaped = $params{query};
        $escaped =~ s/'/\\'/g;
        push @where, "position(message, '$escaped') > 0";
    }

    # Build query
    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $order = $params{order} // 'DESC';
    my $limit = $params{limit} // 500;
    my $offset = $params{offset} // 0;

    my $sql = qq{SELECT toString(id) as id, formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts, level, service, host, message, raw, meta as meta_json FROM $table $where_sql ORDER BY timestamp $order LIMIT $limit OFFSET $offset};

    my $results = $self->_query_json($sql);

    # Rename ts back to timestamp for API response
    for my $row (@$results) {
        $row->{timestamp} = delete $row->{ts};
    }

    # Parse meta JSON
    for my $row (@$results) {
        $row->{meta} = eval { $self->_json->decode($row->{meta_json} // '{}') } // {};
        delete $row->{meta_json};
    }

    return $results;
}

# Count logs
sub count {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my @where;

    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        push @where, "timestamp >= '$from_ts'";
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        push @where, "timestamp <= '$to_ts'";
    }
    if ($params{level}) {
        push @where, "level = '$params{level}'";
    }
    if ($params{service}) {
        push @where, "service = '$params{service}'";
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = "SELECT count() as cnt FROM $table $where_sql";
    my $result = $self->_query_json($sql);

    return $result->[0]{cnt} // 0;
}

# Field statistics
sub field_stats {
    my ($self, $field, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $limit = $params{limit} // 10;

    my @where;
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        push @where, "timestamp >= '$from_ts'";
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        push @where, "timestamp <= '$to_ts'";
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = qq{
        SELECT $field as value, count() as count
        FROM $table
        $where_sql
        GROUP BY $field
        ORDER BY count DESC
        LIMIT $limit
    };

    return $self->_query_json($sql);
}

# Time histogram
sub histogram {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $interval = $params{interval} // '1 hour';

    # Convert interval to ClickHouse function
    my $time_func;
    if ($interval =~ /minute/i) {
        $time_func = "toStartOfMinute(timestamp)";
    } elsif ($interval =~ /hour/i) {
        $time_func = "toStartOfHour(timestamp)";
    } elsif ($interval =~ /day/i) {
        $time_func = "toStartOfDay(timestamp)";
    } else {
        $time_func = "toStartOfHour(timestamp)";
    }

    my @where;
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        push @where, "timestamp >= '$from_ts'";
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        push @where, "timestamp <= '$to_ts'";
    }
    if ($params{level}) {
        push @where, "level = '$params{level}'";
    }
    if ($params{service}) {
        push @where, "service = '$params{service}'";
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = qq{
        SELECT
            formatDateTime($time_func, '%Y-%m-%d %H:%i:%S') as bucket,
            count() as count
        FROM $table
        $where_sql
        GROUP BY bucket
        ORDER BY bucket ASC
    };

    return $self->_query_json($sql);
}

# Get available fields
sub get_fields {
    my ($self) = @_;

    return [
        { name => 'timestamp', type => 'date' },
        { name => 'level', type => 'keyword' },
        { name => 'service', type => 'keyword' },
        { name => 'host', type => 'keyword' },
        { name => 'message', type => 'text' },
        { name => 'raw', type => 'text' },
    ];
}

# Cleanup old logs (handled by TTL, but manual option)
sub cleanup {
    my ($self, $days) = @_;

    $days //= $self->retention_days;

    my $table = $self->database . '.' . $self->table;

    my $sql = qq{
        ALTER TABLE $table
        DELETE WHERE timestamp < now() - INTERVAL $days DAY
    };

    $self->_query($sql);

    # Optimize table
    $self->_query("OPTIMIZE TABLE $table FINAL");

    return 1;
}

# Get database stats
sub stats {
    my ($self) = @_;

    my $table = $self->database . '.' . $self->table;

    my $count_sql = "SELECT count() as total FROM $table";
    my $count_result = $self->_query_json($count_sql);

    my $range_sql = qq{
        SELECT
            min(timestamp) as oldest,
            max(timestamp) as newest
        FROM $table
    };
    my $range_result = $self->_query_json($range_sql);

    my $size_sql = qq{
        SELECT
            sum(bytes) as bytes,
            sum(rows) as rows
        FROM system.parts
        WHERE database = '$self->{database}' AND table = '$self->{table}' AND active
    };
    my $size_result = $self->_query_json($size_sql);

    return {
        total_logs => $count_result->[0]{total} // 0,
        oldest_log => $range_result->[0]{oldest},
        newest_log => $range_result->[0]{newest},
        db_size_bytes => $size_result->[0]{bytes} // 0,
        db_size_mb => sprintf('%.2f', ($size_result->[0]{bytes} // 0) / 1024 / 1024),
        total_rows => $size_result->[0]{rows} // 0,
    };
}

# Check connection
sub ping {
    my ($self) = @_;

    eval {
        $self->_query('SELECT 1');
    };

    return $@ ? 0 : 1;
}

sub disconnect {
    my ($self) = @_;
    $self->flush();  # Flush any remaining logs
}

sub DEMOLISH {
    my ($self) = @_;
    $self->disconnect();
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse - ClickHouse storage backend for high-volume logs

=head1 SYNOPSIS

    use Purl::Storage::ClickHouse;

    my $storage = Purl::Storage::ClickHouse->new(
        host           => 'localhost',
        port           => 8123,
        database       => 'purl',
        retention_days => 30,
    );

    # Insert logs
    $storage->insert_batch(\@normalized_logs);

    # Search
    my $results = $storage->search(
        from    => '2024-12-10T00:00:00Z',
        level   => 'ERROR',
        query   => 'connection refused',
        limit   => 100,
    );

=head1 FEATURES

=over 4

=item * MergeTree engine with automatic partitioning by day

=item * TTL-based automatic data retention

=item * Materialized views for fast aggregations

=item * Full-text search with tokenbf_v1 index

=item * Batch inserts with buffering

=back

=cut

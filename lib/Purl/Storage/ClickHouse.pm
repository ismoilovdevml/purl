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
use Time::HiRes qw(time);

# Consume roles for modular functionality
with 'Purl::Storage::ClickHouse::Query';
with 'Purl::Storage::ClickHouse::Cache';
with 'Purl::Storage::ClickHouse::Alerts';
with 'Purl::Storage::ClickHouse::SavedSearches';

# Configuration
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

# Performance tuning
has 'max_execution_time' => (
    is      => 'ro',
    default => 30,  # seconds
);

has 'max_rows_to_read' => (
    is      => 'ro',
    default => 1_000_000,
);

has 'use_query_cache' => (
    is      => 'ro',
    default => 1,
);

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

# Async insert buffer
has '_buffer' => (
    is      => 'rw',
    default => sub { [] },
);

has 'buffer_size' => (
    is      => 'ro',
    default => 5000,  # Increased for better throughput
);

has 'flush_interval' => (
    is      => 'ro',
    default => 1,  # seconds
);

has '_last_flush' => (
    is      => 'rw',
    default => sub { time() },
);

# Note: Cache attributes are provided by Purl::Storage::ClickHouse::Cache role

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

sub BUILD {
    my ($self) = @_;
    $self->_init_schema();
}

# Note: SQL injection prevention helpers are provided by Purl::Storage::ClickHouse::Query role

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

# ClickHouse performance settings
sub _query_settings {
    my ($self) = @_;
    my @settings = (
        'max_execution_time=' . $self->max_execution_time,
        'max_rows_to_read=' . $self->max_rows_to_read,
        'optimize_read_in_order=1',
        'use_uncompressed_cache=1',
        'load_balancing=nearest_hostname',
        'prefer_localhost_replica=1',
        'async_insert=1',
        'wait_for_async_insert=0',
    );
    return join('&', @settings);
}

sub _query {
    my ($self, $sql, %opts) = @_;

    my $start = time();
    my $url = $self->_base_url . '/?' . $self->_auth_params;
    $url .= '&' . $self->_query_settings unless $opts{no_settings};

    if ($opts{format}) {
        $url .= '&default_format=' . $opts{format};
    }

    my $response = $self->_http->post($url, {
        content => $sql,
        headers => {
            'Content-Type' => 'text/plain',
            'X-ClickHouse-Format' => $opts{format} // 'TabSeparated',
        },
    });

    my $elapsed = time() - $start;
    $self->_metrics->{queries_total}++;
    $self->_metrics->{query_time_total} += $elapsed;

    unless ($response->{success}) {
        $self->_metrics->{errors_total}++;
        die "ClickHouse error: $response->{status} - $response->{content}";
    }

    return $response->{content};
}

# Note: Cache management methods are provided by Purl::Storage::ClickHouse::Cache role

sub _query_json {
    my ($self, $sql, %opts) = @_;

    # Check cache for read queries
    my $cache_key;
    my $is_select = $sql =~ /^\s*SELECT/i;
    if ($is_select && !$opts{no_cache}) {
        $cache_key = $self->_get_cache_key($sql);
        if (my $cached = $self->_get_cached($cache_key)) {
            return $cached;
        }
    }

    my $result = $self->_query($sql, format => 'JSONEachRow');

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

# Get metrics for monitoring
sub get_metrics {
    my ($self) = @_;
    my $m = $self->_metrics;
    return {
        %$m,
        cache_hit_rate => $m->{queries_total} > 0
            ? sprintf('%.1f%%', ($m->{queries_cached} / $m->{queries_total}) * 100)
            : '0%',
        avg_query_time => $m->{queries_total} > 0
            ? sprintf('%.3fs', $m->{query_time_total} / $m->{queries_total})
            : '0s',
        buffer_size => scalar @{$self->_buffer},
    };
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

    # Create logs table with MergeTree engine - optimized schema
    my $table = $self->database . '.' . $self->table;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS $table (
            id UUID DEFAULT generateUUIDv4(),
            timestamp DateTime64(3),
            level LowCardinality(String),
            service LowCardinality(String),
            host LowCardinality(String),
            message String CODEC(ZSTD(3)),
            raw String CODEC(ZSTD(3)),
            meta String CODEC(ZSTD(3)),

            INDEX idx_level level TYPE set(100) GRANULARITY 4,
            INDEX idx_service service TYPE set(1000) GRANULARITY 4,
            INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4
        )
        ENGINE = MergeTree()
        PARTITION BY toYYYYMMDD(timestamp)
        ORDER BY (service, level, timestamp)
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

    # Create saved searches table
    my $db = $self->database;
    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.saved_searches (
            id UUID DEFAULT generateUUIDv4(),
            name String,
            query String,
            time_range String DEFAULT '15m',
            created_at DateTime DEFAULT now()
        )
        ENGINE = MergeTree()
        ORDER BY created_at
    });

    # Create alerts table
    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.alerts (
            id UUID DEFAULT generateUUIDv4(),
            name String,
            query String,
            condition String,
            threshold UInt32 DEFAULT 10,
            window_minutes UInt32 DEFAULT 5,
            notify_type LowCardinality(String) DEFAULT 'webhook',
            notify_target String,
            enabled UInt8 DEFAULT 1,
            last_triggered DateTime DEFAULT toDateTime(0),
            created_at DateTime DEFAULT now()
        )
        ENGINE = MergeTree()
        ORDER BY created_at
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

# Flush buffer to ClickHouse with async insert
sub flush {
    my ($self) = @_;

    return 0 unless @{$self->_buffer};

    my @logs = @{$self->_buffer};
    $self->_buffer([]);
    $self->_last_flush(time());

    my $table = $self->database . '.' . $self->table;

    # Use async_insert for better throughput
    my $url = $self->_base_url . '/?' . $self->_auth_params;
    $url .= '&async_insert=1&wait_for_async_insert=0';
    $url .= '&query=' . uri_escape("INSERT INTO $table FORMAT JSONEachRow");

    my @rows;
    my $bytes = 0;
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
        die "ClickHouse insert error: $response->{status} - $response->{content}";
    }

    # Update metrics
    $self->_metrics->{inserts_total} += scalar @logs;
    $self->_metrics->{bytes_inserted} += $bytes;

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

# Search logs (SQL injection protected)
sub search {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my @where;

    # Time range - convert ISO format to ClickHouse format
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        if ($from_ts =~ /^[\d\-: \.]+$/) {  # Validate timestamp format
            push @where, "timestamp >= " . $self->_quote_string($from_ts);
        }
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        if ($to_ts =~ /^[\d\-: \.]+$/) {  # Validate timestamp format
            push @where, "timestamp <= " . $self->_quote_string($to_ts);
        }
    }

    # Level filter (validated against whitelist)
    if ($params{level}) {
        if (ref $params{level} eq 'ARRAY') {
            my @valid_levels = grep { defined } map { $self->_validate_level($_) } @{$params{level}};
            if (@valid_levels) {
                my $levels = join(',', map { $self->_quote_string($_) } @valid_levels);
                push @where, "level IN ($levels)";
            }
        } else {
            my $valid_level = $self->_validate_level($params{level});
            if ($valid_level) {
                push @where, "level = " . $self->_quote_string($valid_level);
            }
        }
    }

    # Service filter (sanitized)
    if ($params{service}) {
        my $service = $self->_sanitize_identifier($params{service});
        if ($service) {
            if ($service =~ /\*/) {
                my $pattern = $service;
                $pattern =~ s/\*/%/g;
                push @where, "service LIKE " . $self->_quote_string($pattern);
            } else {
                push @where, "service = " . $self->_quote_string($service);
            }
        }
    }

    # Host filter (sanitized)
    if ($params{host}) {
        my $host = $self->_sanitize_identifier($params{host});
        if ($host) {
            push @where, "host = " . $self->_quote_string($host);
        }
    }

    # Full-text search in message (properly escaped)
    if ($params{query}) {
        push @where, "position(message, " . $self->_quote_string($params{query}) . ") > 0";
    }

    # Build query
    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $order = $self->_validate_order($params{order});
    my $limit = $self->_validate_int($params{limit}, 1, 10000) // 500;
    my $offset = $self->_validate_int($params{offset}, 0, 1000000) // 0;

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

# Count logs (SQL injection protected)
sub count {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my @where;

    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        if ($from_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp >= " . $self->_quote_string($from_ts);
        }
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        if ($to_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp <= " . $self->_quote_string($to_ts);
        }
    }
    if ($params{level}) {
        my $valid_level = $self->_validate_level($params{level});
        if ($valid_level) {
            push @where, "level = " . $self->_quote_string($valid_level);
        }
    }
    if ($params{service}) {
        my $service = $self->_sanitize_identifier($params{service});
        if ($service) {
            push @where, "service = " . $self->_quote_string($service);
        }
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = "SELECT count() as cnt FROM $table $where_sql";
    my $result = $self->_query_json($sql);

    return $result->[0]{cnt} // 0;
}

# Field statistics (SQL injection protected)
sub field_stats {
    my ($self, $field, %params) = @_;

    # Validate field name (whitelist)
    my $valid_field = $self->_validate_field($field);
    unless ($valid_field) {
        return [];  # Invalid field, return empty
    }

    my $table = $self->database . '.' . $self->table;
    my $limit = $self->_validate_int($params{limit}, 1, 1000) // 10;

    my @where;
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        if ($from_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp >= " . $self->_quote_string($from_ts);
        }
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        if ($to_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp <= " . $self->_quote_string($to_ts);
        }
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    my $sql = qq{
        SELECT $valid_field as value, count() as count
        FROM $table
        $where_sql
        GROUP BY $valid_field
        ORDER BY count DESC
        LIMIT $limit
    };

    return $self->_query_json($sql);
}

# Time histogram with level breakdown (SQL injection protected)
sub histogram {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $interval = $params{interval} // '1 hour';

    # Convert interval to ClickHouse function (whitelist approach)
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
        if ($from_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp >= " . $self->_quote_string($from_ts);
        }
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        if ($to_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp <= " . $self->_quote_string($to_ts);
        }
    }
    if ($params{level}) {
        my $valid_level = $self->_validate_level($params{level});
        if ($valid_level) {
            push @where, "level = " . $self->_quote_string($valid_level);
        }
    }
    if ($params{service}) {
        my $service = $self->_sanitize_identifier($params{service});
        if ($service) {
            push @where, "service = " . $self->_quote_string($service);
        }
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    # Query with level breakdown for stacked bars
    my $sql = qq{
        SELECT
            formatDateTime($time_func, '%Y-%m-%dT%H:%i:%S') as time,
            count() as count,
            countIf(level IN ('ERROR', 'CRITICAL', 'EMERGENCY', 'ALERT')) as errors,
            countIf(level = 'WARNING') as warnings,
            countIf(level IN ('INFO', 'NOTICE')) as info,
            countIf(level IN ('DEBUG', 'TRACE')) as debug
        FROM $table
        $where_sql
        GROUP BY time
        ORDER BY time ASC
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

# Get table statistics for analytics
sub get_table_stats {
    my ($self) = @_;

    my $sql = qq{
        SELECT
            table,
            sum(rows) as rows,
            sum(bytes) as bytes,
            count() as partitions,
            max(modification_time) as last_modified
        FROM system.parts
        WHERE database = '$self->{database}' AND active
        GROUP BY table
        ORDER BY bytes DESC
    };

    return $self->_query_json($sql);
}

# Get slow queries for analytics
sub get_slow_queries {
    my ($self, $limit) = @_;
    $limit //= 10;

    my $sql = qq{
        SELECT
            query,
            query_duration_ms as duration_ms,
            read_rows,
            memory_usage,
            formatDateTime(event_time, '%Y-%m-%dT%H:%i:%SZ') as event_time
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND query_kind = 'Select'
          AND query_duration_ms > 100
          AND query NOT LIKE '%system.%'
        ORDER BY query_duration_ms DESC
        LIMIT $limit
    };

    return $self->_query_json($sql);
}

# Update retention TTL
sub update_retention {
    my ($self, $days) = @_;

    my $table = $self->database . '.' . $self->table;

    # Modify TTL on the table
    my $sql = qq{
        ALTER TABLE $table
        MODIFY TTL timestamp + INTERVAL $days DAY
    };

    $self->_query($sql);

    return { success => 1, days => $days };
}

sub disconnect {
    my ($self) = @_;
    $self->flush();  # Flush any remaining logs
}

sub DEMOLISH {
    my ($self) = @_;
    $self->disconnect();
}

# Note: Saved Searches and Alerts CRUD methods are provided by
# Purl::Storage::ClickHouse::SavedSearches and Purl::Storage::ClickHouse::Alerts roles

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

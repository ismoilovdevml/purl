package Purl::Storage::ClickHouse::Schema;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use URI::Escape qw(uri_escape);
use namespace::clean;

# ============================================
# Cluster / Replication Helpers
# ============================================

# Returns true when running in ClickHouse cluster mode
sub is_cluster_mode {
    my ($self) = @_;
    return $self->cluster_name ne '';
}

# Build the appropriate MergeTree engine clause.
# In cluster mode: ReplicatedMergeTree with ZooKeeper paths.
# In single mode:  Plain MergeTree (default, backward compatible).
sub _engine_mergetree {
    my ($self, $table_path) = @_;
    if ($self->is_cluster_mode) {
        return "ReplicatedMergeTree('/clickhouse/tables/{shard}/$table_path', '{replica}')";
    }
    return 'MergeTree()';
}

# Build engine clause for ReplacingMergeTree (used by pipelines, dashboards, patterns)
sub _engine_replacing_mergetree {
    my ($self, $table_path, $ver_column) = @_;
    if ($self->is_cluster_mode) {
        return "ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/$table_path', '{replica}', $ver_column)";
    }
    return "ReplacingMergeTree($ver_column)";
}

# Build engine clause for SummingMergeTree (used by materialized view targets)
sub _engine_summing_mergetree {
    my ($self, $table_path) = @_;
    if ($self->is_cluster_mode) {
        return "ReplicatedSummingMergeTree('/clickhouse/tables/{shard}/$table_path', '{replica}')";
    }
    return 'SummingMergeTree()';
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

    # Create logs table — engine adapts to cluster mode automatically
    my $table = $self->database . '.' . $self->table;
    my $logs_engine = $self->_engine_mergetree('logs');

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
            trace_id String DEFAULT '' CODEC(ZSTD(3)),
            request_id String DEFAULT '' CODEC(ZSTD(3)),
            span_id String DEFAULT '' CODEC(ZSTD(3)),
            parent_span_id String DEFAULT '' CODEC(ZSTD(3)),

            INDEX idx_level level TYPE set(100) GRANULARITY 4,
            INDEX idx_service service TYPE set(1000) GRANULARITY 4,
            INDEX idx_message message TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 4,
            INDEX idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 4,
            INDEX idx_request_id request_id TYPE bloom_filter(0.01) GRANULARITY 4
        )
        ENGINE = $logs_engine
        PARTITION BY toYYYYMMDD(timestamp)
        ORDER BY (service, level, timestamp)
        TTL toDateTime(timestamp) + INTERVAL $self->{retention_days} DAY
        SETTINGS index_granularity = 8192
    });

    # Add trace columns if they don't exist (for existing tables)
    for my $col (qw(trace_id request_id span_id parent_span_id)) {
        eval {
            $self->_query(qq{
                ALTER TABLE $table ADD COLUMN IF NOT EXISTS $col String DEFAULT '' CODEC(ZSTD(3))
            });
        };
    }

    # Add trace indexes if they don't exist
    eval {
        $self->_query(qq{
            ALTER TABLE $table ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter(0.01) GRANULARITY 4
        });
        $self->_query(qq{
            ALTER TABLE $table ADD INDEX IF NOT EXISTS idx_request_id request_id TYPE bloom_filter(0.01) GRANULARITY 4
        });
    };

    # Add composite indexes for common query patterns (performance optimization)
    eval {
        $self->_query(qq{
            ALTER TABLE $table ADD INDEX IF NOT EXISTS idx_service_level (service, level) TYPE set(1000) GRANULARITY 4
        });
    };

    # Create materialized view for level stats
    my $level_stats_engine = $self->_engine_summing_mergetree('logs_level_stats');
    $self->_query(qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS ${table}_level_stats
        ENGINE = $level_stats_engine
        ORDER BY (date, level)
        AS SELECT
            toDate(timestamp) as date,
            level,
            count() as count
        FROM $table
        GROUP BY date, level
    });

    # Create materialized view for service stats
    my $service_stats_engine = $self->_engine_summing_mergetree('logs_service_stats');
    $self->_query(qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS ${table}_service_stats
        ENGINE = $service_stats_engine
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
    my $saved_engine = $self->_engine_mergetree('saved_searches');
    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.saved_searches (
            id UUID DEFAULT generateUUIDv4(),
            name String,
            query String,
            time_range String DEFAULT '15m',
            created_at DateTime DEFAULT now()
        )
        ENGINE = $saved_engine
        ORDER BY created_at
    });

    # Create alerts table
    my $alerts_engine = $self->_engine_mergetree('alerts');
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
        ENGINE = $alerts_engine
        ORDER BY created_at
    });

    # Create log patterns table for pattern-based grouping
    my $patterns_engine = $self->_engine_replacing_mergetree('log_patterns', 'last_seen');
    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.log_patterns (
            pattern_hash UInt64,
            pattern String,
            sample_message String,
            service LowCardinality(String),
            level LowCardinality(String),
            first_seen DateTime64(3),
            last_seen DateTime64(3),
            occurrence_count UInt64
        )
        ENGINE = $patterns_engine
        ORDER BY (pattern_hash, service, level)
        TTL toDateTime(first_seen) + INTERVAL $self->{retention_days} DAY
    });

    # Create materialized view to auto-populate patterns
    # Pattern extraction: replace UUIDs, IPs, numbers, dates with placeholders
    $self->_query(qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS ${table}_patterns_mv TO ${db}.log_patterns AS
        SELECT
            cityHash64(
                replaceRegexpAll(
                    replaceRegexpAll(
                        replaceRegexpAll(
                            replaceRegexpAll(
                                replaceRegexpAll(message,
                                    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<UUID>'),
                                '[0-9]{1,3}\\\\.[0-9]{1,3}\\\\.[0-9]{1,3}\\\\.[0-9]{1,3}', '<IP>'),
                            '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}', '<DATETIME>'),
                        '\\\\b[0-9]+\\\\b', '<NUM>'),
                    '[a-fA-F0-9]{24,}', '<HEX>')
            ) as pattern_hash,
            replaceRegexpAll(
                replaceRegexpAll(
                    replaceRegexpAll(
                        replaceRegexpAll(
                            replaceRegexpAll(message,
                                '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<UUID>'),
                            '[0-9]{1,3}\\\\.[0-9]{1,3}\\\\.[0-9]{1,3}\\\\.[0-9]{1,3}', '<IP>'),
                        '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}', '<DATETIME>'),
                    '\\\\b[0-9]+\\\\b', '<NUM>'),
                '[a-fA-F0-9]{24,}', '<HEX>')
            as pattern,
            any(message) as sample_message,
            service,
            level,
            min(timestamp) as first_seen,
            max(timestamp) as last_seen,
            count() as occurrence_count
        FROM $table
        GROUP BY pattern_hash, pattern, service, level
    });
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Schema - database/table/materialized-view creation for the logs
and pattern tables, and the cluster-aware MergeTree engine clauses every
storage role uses for its own tables.

=cut

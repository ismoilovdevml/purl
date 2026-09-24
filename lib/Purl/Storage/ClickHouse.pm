package Purl::Storage::ClickHouse;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

# Consume roles for modular functionality
with 'Purl::Storage::ClickHouse::Query';
with 'Purl::Storage::ClickHouse::KQL';
with 'Purl::Storage::ClickHouse::Cache';
with 'Purl::Storage::ClickHouse::Alerts';
with 'Purl::Storage::ClickHouse::SavedSearches';
with 'Purl::Storage::ClickHouse::Patterns';
with 'Purl::Storage::ClickHouse::Audit';
with 'Purl::Storage::ClickHouse::Backup';
with 'Purl::Storage::ClickHouse::Pipeline';
with 'Purl::Storage::ClickHouse::Dashboard';
with 'Purl::Storage::ClickHouse::K8sHealth';
with 'Purl::Storage::ClickHouse::Agents';
with 'Purl::Storage::ClickHouse::CircuitBreaker';
with 'Purl::Storage::ClickHouse::Connection';
with 'Purl::Storage::ClickHouse::QuerySettings';
with 'Purl::Storage::ClickHouse::JsonColumn';
with 'Purl::Storage::ClickHouse::Schema';
with 'Purl::Storage::ClickHouse::K8sColumns';
with 'Purl::Storage::ClickHouse::Ingest';
with 'Purl::Storage::ClickHouse::Search';
with 'Purl::Storage::ClickHouse::Traces';

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

# Cluster name: when set, enables ReplicatedMergeTree engines.
# Reads from PURL_CLICKHOUSE_CLUSTER env var or constructor arg.
has 'cluster_name' => (
    is      => 'ro',
    default => sub { $ENV{PURL_CLICKHOUSE_CLUSTER} // '' },
);

# Performance tuning
has 'max_execution_time' => (
    is      => 'ro',
    default => 30,  # seconds
);

has 'max_rows_to_read' => (
    is      => 'ro',
    default => 0,  # unlimited — max_execution_time is the safety net
);

# Per-query memory cap in bytes (#108), sent as max_memory_usage with sort and
# GROUP BY spilling at a quarter of it. 256 MiB: the heaviest Logs-page query
# measured at 31 MiB with lazy materialisation, an ingest batch with its
# materialised views at 121 MiB. 0 = leave it to the server profile.
has 'max_query_memory' => (
    is      => 'ro',
    default => 268_435_456,
);

has 'use_query_cache' => (
    is      => 'ro',
    default => 1,
);

# Note: HTTP transport attributes live in Purl::Storage::ClickHouse::Connection,
# the ingest buffer in ::Ingest and circuit-breaker state in ::CircuitBreaker.

sub BUILD {
    my ($self) = @_;
    $self->_init_schema();
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
        buffer_max  => $self->buffer_max,
        durable     => $self->durable,
    };
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

    my $db_quoted = $self->_quote_string($self->database);
    my $table_quoted = $self->_quote_string($self->table);
    my $size_sql = qq{
        SELECT
            sum(bytes) as bytes,
            sum(rows) as rows
        FROM system.parts
        WHERE database = $db_quoted AND table = $table_quoted AND active
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

# Get table statistics for analytics
sub get_table_stats {
    my ($self) = @_;

    my $db_quoted = $self->_quote_string($self->database);
    my $sql = qq{
        SELECT
            table,
            sum(rows) as rows,
            sum(bytes) as bytes,
            count() as partitions,
            max(modification_time) as last_modified
        FROM system.parts
        WHERE database = $db_quoted AND active AND table NOT LIKE '.%' AND table NOT LIKE 'system.%'
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

# Best effort only: flush a buffer left in an object that is freed at runtime
# (e.g. the old storage after a settings-driven rebuild). The shutdown flush
# is explicit (Purl::API::Server::Shutdown) because during global destruction
# the HTTP client / JSON encoder a flush needs may already be gone (#90) —
# attempting it then only produces "(in cleanup)" noise, so it is skipped.
sub DEMOLISH {
    my ($self, $in_global_destruction) = @_;
    return if $in_global_destruction || ${^GLOBAL_PHASE} eq 'DESTRUCT';
    eval { $self->disconnect(); 1 }
        or warn "ClickHouse buffer flush on destroy failed: $@";
    return;
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

    # Cluster mode (via env or constructor):
    # PURL_CLICKHOUSE_CLUSTER=purl_cluster
    my $clustered = Purl::Storage::ClickHouse->new(
        host         => 'clickhouse-0.clickhouse-headless',
        cluster_name => 'purl_cluster',
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

=item * ReplicatedMergeTree in cluster mode (set PURL_CLICKHOUSE_CLUSTER)

=item * TTL-based automatic data retention

=item * Materialized views for fast aggregations

=item * Full-text search with tokenbf_v1 index

=item * Batch inserts with buffering

=back

=cut
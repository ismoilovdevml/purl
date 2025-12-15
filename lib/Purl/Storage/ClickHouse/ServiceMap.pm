package Purl::Storage::ClickHouse::ServiceMap;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# ============================================
# Service Map Tables Setup
# ============================================

sub _create_service_map_tables {
    my ($self) = @_;
    my $db = $self->database;

    # Service edges table - tracks service-to-service calls
    my $edges_sql = qq{
        CREATE TABLE IF NOT EXISTS $db.service_edges (
            source_service LowCardinality(String),
            target_service LowCardinality(String),
            operation String DEFAULT '',
            call_count UInt64 DEFAULT 1,
            error_count UInt64 DEFAULT 0,
            total_duration_ms Float64 DEFAULT 0,
            min_duration_ms Float64 DEFAULT 0,
            max_duration_ms Float64 DEFAULT 0,
            last_seen DateTime DEFAULT now(),
            date Date DEFAULT today()
        )
        ENGINE = SummingMergeTree()
        PARTITION BY toYYYYMM(date)
        ORDER BY (source_service, target_service, operation, date)
        TTL date + INTERVAL 30 DAY
    };
    $self->_query($edges_sql);

    # Service health aggregation table
    my $health_sql = qq{
        CREATE TABLE IF NOT EXISTS $db.service_health (
            service LowCardinality(String),
            total_requests UInt64 DEFAULT 0,
            error_requests UInt64 DEFAULT 0,
            avg_duration_ms Float64 DEFAULT 0,
            p50_duration_ms Float64 DEFAULT 0,
            p95_duration_ms Float64 DEFAULT 0,
            p99_duration_ms Float64 DEFAULT 0,
            last_seen DateTime DEFAULT now(),
            date Date DEFAULT today()
        )
        ENGINE = SummingMergeTree()
        PARTITION BY toYYYYMM(date)
        ORDER BY (service, date)
        TTL date + INTERVAL 30 DAY
    };
    $self->_query($health_sql);

    # Materialized view to extract service edges from logs with span correlation
    my $mv_edges_sql = qq{
        CREATE MATERIALIZED VIEW IF NOT EXISTS $db.service_edges_mv
        TO $db.service_edges
        AS SELECT
            parent.service AS source_service,
            child.service AS target_service,
            child.message AS operation,
            1 AS call_count,
            if(child.level IN ('ERROR', 'FATAL'), 1, 0) AS error_count,
            0 AS total_duration_ms,
            0 AS min_duration_ms,
            0 AS max_duration_ms,
            child.timestamp AS last_seen,
            toDate(child.timestamp) AS date
        FROM $db.logs AS child
        INNER JOIN $db.logs AS parent
            ON child.parent_span_id = parent.span_id
            AND child.trace_id = parent.trace_id
            AND child.service != parent.service
        WHERE child.parent_span_id != ''
            AND child.span_id != ''
            AND child.trace_id != ''
    };

    # Try to create MV, ignore if columns don't exist yet
    eval { $self->_query($mv_edges_sql) };
}

# ============================================
# Service Dependencies API
# ============================================

# Get all service dependencies (edges)
sub get_service_dependencies {
    my ($self, %params) = @_;

    my $from = $params{from};
    my $to   = $params{to};
    my $db   = $self->database;

    my @conditions;
    push @conditions, "date >= toDate(parseDateTimeBestEffort('$from'))" if $from;
    push @conditions, "date <= toDate(parseDateTimeBestEffort('$to'))" if $to;

    my $where = @conditions ? 'WHERE ' . join(' AND ', @conditions) : '';

    my $sql = qq{
        SELECT
            source_service,
            target_service,
            calls AS call_count,
            errors AS error_count,
            avg_dur AS avg_duration_ms,
            last_ts AS last_seen
        FROM (
            SELECT
                source_service,
                target_service,
                sum(call_count) AS calls,
                sum(error_count) AS errors,
                if(sum(call_count) > 0, sum(total_duration_ms) / sum(call_count), 0) AS avg_dur,
                formatDateTime(max(last_seen), '%Y-%m-%dT%H:%i:%S') || 'Z' AS last_ts
            FROM $db.service_edges
            $where
            GROUP BY source_service, target_service
        )
        ORDER BY call_count DESC
        LIMIT 1000
    };

    return $self->_query_json($sql);
}

# Get all unique services
sub get_services {
    my ($self, %params) = @_;

    my $from = $params{from};
    my $to   = $params{to};
    my $db   = $self->database;

    my @conditions;
    push @conditions, "timestamp >= parseDateTimeBestEffort('$from')" if $from;
    push @conditions, "timestamp <= parseDateTimeBestEffort('$to')" if $to;

    my $where = @conditions ? 'WHERE ' . join(' AND ', @conditions) : '';

    my $sql = qq{
        SELECT
            service,
            count() AS log_count,
            countIf(level IN ('ERROR', 'FATAL')) AS error_count,
            formatDateTime(min(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' AS first_seen,
            formatDateTime(max(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' AS last_seen
        FROM $db.logs
        $where
        GROUP BY service
        ORDER BY log_count DESC
    };

    return $self->_query_json($sql);
}

# Get upstream services (services that call this service)
sub get_upstream_services {
    my ($self, $service, %params) = @_;

    my $db = $self->database;
    my $safe_service = $self->_quote_string($service);

    my $sql = qq{
        SELECT
            service,
            calls AS call_count,
            errors AS error_count,
            avg_dur AS avg_duration_ms
        FROM (
            SELECT
                source_service AS service,
                sum(call_count) AS calls,
                sum(error_count) AS errors,
                if(sum(call_count) > 0, sum(total_duration_ms) / sum(call_count), 0) AS avg_dur
            FROM $db.service_edges
            WHERE target_service = $safe_service
            GROUP BY source_service
        )
        ORDER BY call_count DESC
        LIMIT 100
    };

    return $self->_query_json($sql);
}

# Get downstream services (services that this service calls)
sub get_downstream_services {
    my ($self, $service, %params) = @_;

    my $db = $self->database;
    my $safe_service = $self->_quote_string($service);

    my $sql = qq{
        SELECT
            service,
            calls AS call_count,
            errors AS error_count,
            avg_dur AS avg_duration_ms
        FROM (
            SELECT
                target_service AS service,
                sum(call_count) AS calls,
                sum(error_count) AS errors,
                if(sum(call_count) > 0, sum(total_duration_ms) / sum(call_count), 0) AS avg_dur
            FROM $db.service_edges
            WHERE source_service = $safe_service
            GROUP BY target_service
        )
        ORDER BY call_count DESC
        LIMIT 100
    };

    return $self->_query_json($sql);
}

# ============================================
# Service Health API
# ============================================

# Get service health metrics
sub get_service_health {
    my ($self, %params) = @_;

    my $from = $params{from};
    my $to   = $params{to};
    my $db   = $self->database;

    my @conditions;
    push @conditions, "timestamp >= parseDateTimeBestEffort('$from')" if $from;
    push @conditions, "timestamp <= parseDateTimeBestEffort('$to')" if $to;

    my $where = @conditions ? 'WHERE ' . join(' AND ', @conditions) : '';

    my $sql = qq{
        SELECT
            service,
            count() AS total_requests,
            countIf(level IN ('ERROR', 'FATAL')) AS error_count,
            round(countIf(level IN ('ERROR', 'FATAL')) * 100.0 / count(), 2) AS error_rate,
            count(DISTINCT trace_id) AS trace_count
        FROM $db.logs
        $where
        GROUP BY service
        ORDER BY total_requests DESC
    };

    my $services = $self->_query_json($sql);

    # Calculate health status
    for my $svc (@$services) {
        my $error_rate = $svc->{error_rate} // 0;
        if ($error_rate >= 10) {
            $svc->{health_status} = 'critical';
        } elsif ($error_rate >= 5) {
            $svc->{health_status} = 'degraded';
        } else {
            $svc->{health_status} = 'healthy';
        }
    }

    return $services;
}

# Get single service details
sub get_service_details {
    my ($self, $service, %params) = @_;

    my $from = $params{from} // '1 hour';
    my $db   = $self->database;
    my $safe_service = $self->_quote_string($service);

    # Basic metrics
    my $metrics_sql = qq{
        SELECT
            count() AS total_logs,
            countIf(level = 'ERROR') AS error_count,
            countIf(level = 'WARN') AS warn_count,
            countIf(level = 'INFO') AS info_count,
            countIf(level = 'DEBUG') AS debug_count,
            count(DISTINCT trace_id) AS unique_traces,
            formatDateTime(min(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' AS first_seen,
            formatDateTime(max(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' AS last_seen
        FROM $db.logs
        WHERE service = $safe_service
            AND timestamp >= now() - INTERVAL $from
    };

    my $metrics = $self->_query_json($metrics_sql);

    # Recent errors
    my $errors_sql = qq{
        SELECT
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' AS timestamp,
            level,
            message,
            trace_id
        FROM $db.logs
        WHERE service = $safe_service
            AND level IN ('ERROR', 'FATAL')
            AND timestamp >= now() - INTERVAL $from
        ORDER BY timestamp DESC
        LIMIT 10
    };

    my $errors = $self->_query_json($errors_sql);

    return {
        service => $service,
        metrics => $metrics->[0] // {},
        recent_errors => $errors,
    };
}

# Record service edge (called when span with parent is ingested)
sub record_service_edge {
    my ($self, $source, $target, %opts) = @_;

    my $db = $self->database;
    my $duration = $opts{duration_ms} // 0;
    my $is_error = $opts{is_error} ? 1 : 0;
    my $operation = $self->_quote_string($opts{operation} // '');
    my $safe_source = $self->_quote_string($source);
    my $safe_target = $self->_quote_string($target);

    my $sql = qq{
        INSERT INTO $db.service_edges
        (source_service, target_service, operation, call_count, error_count, total_duration_ms, min_duration_ms, max_duration_ms)
        VALUES ($safe_source, $safe_target, $operation, 1, $is_error, $duration, $duration, $duration)
    };

    eval { $self->_query($sql) };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::ServiceMap - Service dependency tracking and health metrics

=head1 SYNOPSIS

    # In ClickHouse.pm, consume this role:
    with 'Purl::Storage::ClickHouse::ServiceMap';

    # Get service dependencies
    my $deps = $storage->get_service_dependencies(from => '2024-01-01');

    # Get service health
    my $health = $storage->get_service_health();

    # Get upstream/downstream
    my $upstream = $storage->get_upstream_services('api-gateway');
    my $downstream = $storage->get_downstream_services('api-gateway');

=cut

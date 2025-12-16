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

    my $range = $params{from} // '1h';
    my $db   = $self->database;
    my $safe_service = $self->_quote_string($service);

    # Convert range to SQL interval
    my (undef, $range_sql) = _parse_interval_range('1minute', $range);

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
            AND timestamp >= now() - INTERVAL $range_sql
    };

    my $metrics = $self->_query_json($metrics_sql);

    # Recent errors
    my $errors_sql = qq{
        SELECT
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' AS ts,
            level,
            message,
            trace_id
        FROM $db.logs
        WHERE service = $safe_service
            AND level IN ('ERROR', 'FATAL')
            AND timestamp >= now() - INTERVAL $range_sql
        ORDER BY timestamp DESC
        LIMIT 10
    };

    my $errors = $self->_query_json($errors_sql);

    # Recent logs (last 10)
    my $logs_sql = qq{
        SELECT
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' AS ts,
            level,
            message,
            trace_id
        FROM $db.logs
        WHERE service = $safe_service
            AND timestamp >= now() - INTERVAL $range_sql
        ORDER BY timestamp DESC
        LIMIT 10
    };

    my $logs = $self->_query_json($logs_sql);

    return {
        service => $service,
        metrics => $metrics->[0] // {},
        recent_errors => $errors,
        recent_logs => $logs,
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

# ============================================
# Service Metrics Timeseries API
# ============================================

# Get service metrics over time (for charts)
sub get_service_metrics_timeseries {
    my ($self, $service, %params) = @_;

    my $range    = $params{range} // '1h';
    my $interval = $params{interval} // '1minute';
    my $db       = $self->database;
    my $safe_service = $self->_quote_string($service);

    # Determine interval and time range
    my ($interval_sql, $range_sql) = _parse_interval_range($interval, $range);

    my $sql = qq{
        SELECT
            toStartOfInterval(timestamp, INTERVAL $interval_sql) AS time,
            count() AS requests,
            countIf(level IN ('ERROR', 'FATAL')) AS errors,
            countIf(level = 'WARN') AS warnings
        FROM $db.logs
        WHERE service = $safe_service
            AND timestamp >= now() - INTERVAL $range_sql
        GROUP BY time
        ORDER BY time ASC
    };

    my $results = $self->_query_json($sql);

    # Format timestamps
    for my $row (@$results) {
        $row->{time} = $row->{time} . 'Z' if $row->{time} && $row->{time} !~ /Z$/;
    }

    return $results;
}

# Get latency percentiles for a service
sub get_service_latency_percentiles {
    my ($self, $service, %params) = @_;

    my $range = $params{range} // '1h';
    my $db    = $self->database;
    my $safe_service = $self->_quote_string($service);

    my (undef, $range_sql) = _parse_interval_range('1minute', $range);

    # Get percentiles from service_edges (outgoing calls)
    my $sql = qq{
        SELECT
            round(avg(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS avg_ms,
            round(quantile(0.50)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p50_ms,
            round(quantile(0.75)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p75_ms,
            round(quantile(0.90)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p90_ms,
            round(quantile(0.95)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p95_ms,
            round(quantile(0.99)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p99_ms,
            round(min(min_duration_ms), 2) AS min_ms,
            round(max(max_duration_ms), 2) AS max_ms
        FROM $db.service_edges
        WHERE (source_service = $safe_service OR target_service = $safe_service)
            AND date >= toDate(now() - INTERVAL $range_sql)
    };

    my $results = $self->_query_json($sql);
    return $results->[0] // {
        avg_ms => 0, p50_ms => 0, p75_ms => 0,
        p90_ms => 0, p95_ms => 0, p99_ms => 0,
        min_ms => 0, max_ms => 0
    };
}

# Get latency timeseries for charts
sub get_service_latency_timeseries {
    my ($self, $service, %params) = @_;

    my $range    = $params{range} // '1h';
    my $interval = $params{interval} // '1minute';
    my $db       = $self->database;
    my $safe_service = $self->_quote_string($service);

    my ($interval_sql, $range_sql) = _parse_interval_range($interval, $range);

    my $sql = qq{
        SELECT
            toStartOfInterval(last_seen, INTERVAL $interval_sql) AS time,
            round(avg(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS avg_ms,
            round(quantile(0.50)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p50_ms,
            round(quantile(0.95)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p95_ms,
            round(quantile(0.99)(if(call_count > 0, total_duration_ms / call_count, 0)), 2) AS p99_ms
        FROM $db.service_edges
        WHERE (source_service = $safe_service OR target_service = $safe_service)
            AND date >= toDate(now() - INTERVAL $range_sql)
        GROUP BY time
        ORDER BY time ASC
    };

    my $results = $self->_query_json($sql);

    for my $row (@$results) {
        $row->{time} = $row->{time} . 'Z' if $row->{time} && $row->{time} !~ /Z$/;
    }

    return $results;
}

# Helper to parse interval and range strings
sub _parse_interval_range {
    my ($interval, $range) = @_;

    # Map interval strings to SQL
    my %interval_map = (
        '1minute'  => '1 MINUTE',
        '5minute'  => '5 MINUTE',
        '1hour'    => '1 HOUR',
        '1day'     => '1 DAY',
    );

    # Map range strings to SQL
    my %range_map = (
        '15m'  => '15 MINUTE',
        '30m'  => '30 MINUTE',
        '1h'   => '1 HOUR',
        '6h'   => '6 HOUR',
        '12h'  => '12 HOUR',
        '24h'  => '24 HOUR',
        '7d'   => '7 DAY',
        '30d'  => '30 DAY',
    );

    my $interval_sql = $interval_map{$interval} // '1 MINUTE';
    my $range_sql    = $range_map{$range} // '1 HOUR';

    return ($interval_sql, $range_sql);
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

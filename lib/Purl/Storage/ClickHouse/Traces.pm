package Purl::Storage::ClickHouse::Traces;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# Get log context (surrounding logs from same service/host)
sub get_context {
    my ($self, $log_id, %params) = @_;

    my $before = $self->_validate_int($params{before}, 1, 200) // 50;
    my $after  = $self->_validate_int($params{after}, 1, 200) // 50;
    my $table  = $self->database . '.' . $self->table;

    # Validate UUID format
    return { before => [], after => [], reference => undef }
        unless $log_id && $log_id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    # First, get the reference log
    my $ref_sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            timestamp as raw_ts,
            level, service, host, message, raw, meta as meta_json
        FROM $table
        WHERE toString(id) = '$log_id'
        LIMIT 1
    };

    my $ref_result = $self->_query_json($ref_sql, no_cache => 1);
    return { before => [], after => [], reference => undef } unless @$ref_result;

    my $ref_log = $ref_result->[0];
    my $ref_ts = $ref_log->{raw_ts};
    my $service = $self->_quote_string($ref_log->{service});
    my $host = $self->_quote_string($ref_log->{host});

    # Get logs before (same service/host, timestamp < ref)
    my $before_sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            level, service, host, message, raw, meta as meta_json
        FROM $table
        WHERE service = $service
          AND host = $host
          AND timestamp < '$ref_ts'
          AND toString(id) != '$log_id'
        ORDER BY timestamp DESC
        LIMIT $before
    };

    my $before_result = $self->_query_json($before_sql, no_cache => 1);

    # Get logs after (same service/host, timestamp > ref)
    my $after_sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            level, service, host, message, raw, meta as meta_json
        FROM $table
        WHERE service = $service
          AND host = $host
          AND timestamp > '$ref_ts'
          AND toString(id) != '$log_id'
        ORDER BY timestamp ASC
        LIMIT $after
    };

    my $after_result = $self->_query_json($after_sql, no_cache => 1);

    # Process results - rename ts to timestamp and parse meta
    my $process_logs = sub {
        my ($logs) = @_;
        for my $row (@$logs) {
            $row->{timestamp} = delete $row->{ts};
            $row->{meta} = $self->_decode_json_column($row->{meta_json}, {});
            delete $row->{meta_json};
        }
        return $logs;
    };

    # Process reference log
    $ref_log->{timestamp} = delete $ref_log->{ts};
    $ref_log->{meta} = $self->_decode_json_column($ref_log->{meta_json}, {});
    delete $ref_log->{meta_json};
    delete $ref_log->{raw_ts};

    return {
        reference => $ref_log,
        before    => [ reverse @{ $process_logs->($before_result) } ],  # Chronological order
        after     => $process_logs->($after_result),
    };
}

# Get recent traces (grouped by trace_id)
sub get_recent_traces {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $limit = $self->_validate_int($params{limit}, 1, 100) // 20;
    my $range = $params{range} // '24h';

    # Parse range (e.g., '1h', '24h', '7d')
    my $time_clause = '';
    if ($range =~ /^(\d+)([mhd])$/i) {
        my ($num, $unit) = ($1, lc($2));
        my $seconds = $num * ($unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : 86400);
        $time_clause = "AND timestamp >= now() - toIntervalSecond($seconds)";
    }

    my $sql = qq{
        SELECT
            trace_id,
            formatDateTime(min(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' as first_seen,
            formatDateTime(max(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' as last_seen,
            count() as log_count,
            countIf(upper(level) IN ('ERROR', 'CRITICAL', 'EMERGENCY', 'ALERT', 'FATAL')) as error_count,
            groupUniqArray(service) as services,
            dateDiff('millisecond', min(timestamp), max(timestamp)) as duration_ms
        FROM $table
        WHERE trace_id != ''
            $time_clause
        GROUP BY trace_id
        ORDER BY max(timestamp) DESC
        LIMIT $limit
    };

    return $self->_query_json($sql, no_cache => 1);
}

# Search logs by trace ID (all services)
sub search_by_trace {
    my ($self, $trace_id, %params) = @_;

    my $table = $self->database . '.' . $self->table;

    # Validate trace_id
    my $valid_trace = $self->_sanitize_trace_id($trace_id);
    return { hits => [], total => 0 } unless $valid_trace;

    my $limit = $self->_validate_int($params{limit}, 1, 1000) // 200;

    my $sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            level, service, host, message, raw, meta as meta_json,
            trace_id, request_id, span_id, parent_span_id
        FROM $table
        WHERE trace_id = } . $self->_quote_string($valid_trace) . qq{
        ORDER BY timestamp ASC
        LIMIT $limit
    };

    my $results = $self->_query_json($sql, no_cache => 1);

    # Process results
    for my $row (@$results) {
        $row->{timestamp} = delete $row->{ts};
        $row->{meta} = $self->_decode_json_column($row->{meta_json}, {});
        delete $row->{meta_json};
    }

    # Get count
    my $count_sql = qq{
        SELECT count() as cnt FROM $table
        WHERE trace_id = } . $self->_quote_string($valid_trace);
    my $count_result = $self->_query_json($count_sql, no_cache => 1);

    return {
        hits  => $results,
        total => $count_result->[0]{cnt} // scalar @$results,
    };
}

# Get trace timeline (services with time spans)
sub get_trace_timeline {
    my ($self, $trace_id) = @_;

    my $table = $self->database . '.' . $self->table;

    # Validate trace_id
    my $valid_trace = $self->_sanitize_trace_id($trace_id);
    return [] unless $valid_trace;

    my $sql = qq{
        SELECT
            service,
            min(timestamp) as start_time,
            max(timestamp) as end_time,
            count() as log_count,
            countIf(upper(level) IN ('ERROR', 'CRITICAL', 'EMERGENCY', 'ALERT', 'FATAL')) as error_count
        FROM $table
        WHERE trace_id = } . $self->_quote_string($valid_trace) . qq{
        GROUP BY service
        ORDER BY start_time ASC
    };

    my $results = $self->_query_json($sql, no_cache => 1);

    # Format timestamps
    for my $row (@$results) {
        $row->{start_time} =~ s/ /T/;
        $row->{start_time} .= 'Z' unless $row->{start_time} =~ /Z$/;
        $row->{end_time} =~ s/ /T/;
        $row->{end_time} .= 'Z' unless $row->{end_time} =~ /Z$/;
    }

    return $results;
}

# Search logs by request ID
sub search_by_request {
    my ($self, $request_id, %params) = @_;

    my $table = $self->database . '.' . $self->table;

    # Validate request_id
    my $valid_request = $self->_sanitize_trace_id($request_id);
    return { hits => [], total => 0 } unless $valid_request;

    my $limit = $self->_validate_int($params{limit}, 1, 1000) // 200;

    my $sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            level, service, host, message, raw, meta as meta_json,
            trace_id, request_id, span_id, parent_span_id
        FROM $table
        WHERE request_id = } . $self->_quote_string($valid_request) . qq{
        ORDER BY timestamp ASC
        LIMIT $limit
    };

    my $results = $self->_query_json($sql, no_cache => 1);

    # Process results
    for my $row (@$results) {
        $row->{timestamp} = delete $row->{ts};
        $row->{meta} = $self->_decode_json_column($row->{meta_json}, {});
        delete $row->{meta_json};
    }

    return {
        hits  => $results,
        total => scalar @$results,
    };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Traces - log context and trace/request correlation queries.

=cut

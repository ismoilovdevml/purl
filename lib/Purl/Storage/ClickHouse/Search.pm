package Purl::Storage::ClickHouse::Search;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Purl::Util::Time qw(to_clickhouse_ts);
use namespace::clean;

# Convert ISO timestamp (from API) to ClickHouse format for queries
# Uses centralized Purl::Util::Time
sub _convert_to_clickhouse_ts {
    my ($self, $ts) = @_;
    return to_clickhouse_ts($ts);
}

# Search logs (SQL injection protected)
sub search {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    # Use shared builder for secure parameter handling
    my ($where_sql, $bind_params) = $self->_build_where_clause(%params);

    my $order = $self->_validate_order($params{order});
    my $limit = $self->_validate_int($params{limit}, 1, 10000) // 500;
    my $offset = $self->_validate_int($params{offset}, 0, 1000000) // 0;

    my $sql = qq{SELECT toString(id) as id, formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts, level, service, host, message, raw, meta as meta_json FROM $table $where_sql ORDER BY timestamp $order LIMIT $limit OFFSET $offset};

    my $results = $self->_query_json($sql, params => $bind_params);

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
    my ($where_sql, $bind_params) = $self->_build_where_clause(%params);

    my $sql = "SELECT count() as cnt FROM $table $where_sql";
    my $result = $self->_query_json($sql, params => $bind_params);

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

    my ($where_sql, $bind_params) = $self->_build_where_clause(%params);

    # Handle meta.* fields (K8s support) using JSONExtractString
    # Meta field is double-encoded JSON string, so we need to unescape it first
    my $select_field;
    if ($valid_field =~ /^meta\.(\w+)$/) {
        my $sub_field = $1;
        # Strip outer quotes and unescape inner quotes before JSON extraction
        $select_field = "JSONExtractString(replaceAll(substring(meta, 2, length(meta)-2), '\\\\\"', '\"'), '$sub_field')";
    } else {
        $select_field = $valid_field;
    }

    # Build proper WHERE clause for meta fields
    my $where_clause = $where_sql;
    if ($valid_field =~ /^meta\./) {
        if ($where_clause) {
            $where_clause .= " AND $select_field != ''";
        } else {
            $where_clause = "WHERE $select_field != ''";
        }
    }

    my $sql = qq{
        SELECT $select_field as value, count() as count
        FROM $table
        $where_clause
        GROUP BY value
        ORDER BY count DESC
        LIMIT $limit
    };

    return $self->_query_json($sql, params => $bind_params);
}

# Time histogram with level breakdown (SQL injection protected)
sub histogram {
    my ($self, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $interval = $params{interval} // '1 hour';

    # Convert interval to ClickHouse function and step (whitelist approach)
    my ($time_func, $interval_step, $to_start_func);
    if ($interval =~ /minute/i) {
        $time_func = "toStartOfMinute(timestamp)";
        $interval_step = "INTERVAL 1 MINUTE";
        $to_start_func = "toStartOfMinute";
    } elsif ($interval =~ /hour/i) {
        $time_func = "toStartOfHour(timestamp)";
        $interval_step = "INTERVAL 1 HOUR";
        $to_start_func = "toStartOfHour";
    } elsif ($interval =~ /day/i) {
        $time_func = "toStartOfDay(timestamp)";
        $interval_step = "INTERVAL 1 DAY";
        $to_start_func = "toStartOfDay";
    } else {
        $time_func = "toStartOfHour(timestamp)";
        $interval_step = "INTERVAL 1 HOUR";
        $to_start_func = "toStartOfHour";
    }

    my ($where_sql, $bind_params) = $self->_build_where_clause(%params);

    # Calculate time bounds for WITH FILL
    my ($fill_from, $fill_to);
    if ($params{from} && $params{to}) {
        $fill_from = "$to_start_func({p_fill_from:DateTime64(3)})";
        $fill_to = "$to_start_func({p_fill_to:DateTime64(3)})";
        $bind_params->{p_fill_from} = $self->_convert_to_clickhouse_ts($params{from});
        $bind_params->{p_fill_to} = $self->_convert_to_clickhouse_ts($params{to});
    } elsif ($params{range}) {
        # Parse range like '15m', '1h', '24h', '7d'
        my $range = $params{range};
        if ($range =~ /^(\d+)([mhd])$/i) {
            my ($num, $unit) = ($1, lc($2));
            my $seconds = $num * ($unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : 86400);
            $fill_from = "$to_start_func(now() - INTERVAL $seconds SECOND)";
            $fill_to = "$to_start_func(now())";
        } else {
            $fill_from = "$to_start_func(now() - INTERVAL 1 HOUR)";
            $fill_to = "$to_start_func(now())";
        }
    } else {
        $fill_from = "$to_start_func(now() - INTERVAL 1 HOUR)";
        $fill_to = "$to_start_func(now())";
    }

    # Query with level breakdown and WITH FILL for empty buckets
    my $sql = qq{
        SELECT
            formatDateTime(time_bucket, '%Y-%m-%dT%H:%i:%S') || 'Z' as time,
            count as count,
            errors,
            warnings,
            info,
            debug
        FROM (
            SELECT
                $time_func as time_bucket,
                count() as count,
                countIf(level IN ('ERROR', 'CRITICAL', 'EMERGENCY', 'ALERT')) as errors,
                countIf(level = 'WARNING') as warnings,
                countIf(level IN ('INFO', 'NOTICE')) as info,
                countIf(level IN ('DEBUG', 'TRACE')) as debug
            FROM $table
            $where_sql
            GROUP BY time_bucket
            ORDER BY time_bucket ASC
            WITH FILL
                FROM $fill_from
                TO $fill_to + $interval_step
                STEP $interval_step
        )
        ORDER BY time ASC
    };

    return $self->_query_json($sql, params => $bind_params);
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

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Search - log search, count, field statistics and the time
histogram (all bound-parameter queries built by
L<Purl::Storage::ClickHouse::Query>).

=cut

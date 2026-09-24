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

    # Build NEW row hashes: $results may be the query cache's own arrayref, and
    # rewriting it in place (delete ts / meta_json) made every cache hit come
    # back with timestamp undef and meta {}.
    return [ map {
        my %row = %$_;
        $row{timestamp} = delete $row{ts};
        $row{meta}      = $self->_decode_json_column(delete $row{meta_json}, {});
        \%row;
    } @$results ];
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

    # What to group by, and whether an empty value is "not set" and dropped.
    my ($select_field, $skip_empty);
    if ($valid_field =~ /^meta\.(\w+)$/) {
        # The key is whitelisted by _validate_field and still goes in bound.
        $bind_params->{p_meta_key} = $1;
        $select_field = $self->meta_key_sql('{p_meta_key:String}');
        $skip_empty   = 1;
    } elsif ($valid_field eq 'level') {
        # One bucket per level whatever case (#105) or synonym (#110) older
        # rows were stored under.
        $select_field = $self->_level_canonical_sql;
    } else {
        $select_field = $valid_field;
        # A log that did not come from Kubernetes has no namespace/pod/container;
        # an empty bucket would be the biggest one and mean nothing.
        $skip_empty = $self->is_k8s_column($valid_field);
    }

    my $where_clause = $where_sql;
    if ($skip_empty) {
        $where_clause .= ($where_clause ? ' AND ' : 'WHERE ') . "$select_field != ''";
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
    # Fill only between bounds that normalised: an unreadable from/to is ''
    # (no filter), and filling from 1970 built hundreds of thousands of buckets.
    my ($ts_from, $ts_to) = map { $self->_convert_to_clickhouse_ts($_) } @params{qw(from to)};
    if ($ts_from && $ts_to) {
        $fill_from = "$to_start_func({p_fill_from:DateTime64(3)})";
        $fill_to = "$to_start_func({p_fill_to:DateTime64(3)})";
        $bind_params->{p_fill_from} = $ts_from;
        $bind_params->{p_fill_to} = $ts_to;
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

    # Query with level breakdown and WITH FILL for empty buckets. Every case
    # (#105) and synonym (#110) of a level counts in its bucket; FATAL is an
    # error, TRACE is debug.
    my $errors   = $self->_level_literals(qw(ERROR FATAL));
    my $warnings = $self->_level_literals('WARN');
    my $info     = $self->_level_literals('INFO');
    my $debug    = $self->_level_literals(qw(DEBUG TRACE));
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
                countIf(upper(level) IN ($errors)) as errors,
                countIf(upper(level) IN ($warnings)) as warnings,
                countIf(upper(level) IN ($info)) as info,
                countIf(upper(level) IN ($debug)) as debug
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
        { name => 'namespace', type => 'keyword' },
        { name => 'pod', type => 'keyword' },
        { name => 'container', type => 'keyword' },
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

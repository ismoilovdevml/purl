package Purl::Storage::ClickHouse::Patterns;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# Get top patterns for a time range
# Queries logs table directly for real-time pattern analysis
sub get_patterns {
    my ($self, %params) = @_;

    my $db = $self->database;
    my $table = $self->table;
    my $limit = $self->_validate_int($params{limit}, 1, 100) // 30;
    my @where;

    # Service filter
    if ($params{service}) {
        my $service = $self->_sanitize_identifier($params{service});
        if ($service) {
            push @where, "service = " . $self->_quote_string($service);
        }
    }

    # Level filter
    if ($params{level}) {
        my $valid_level = $self->_validate_level($params{level});
        if ($valid_level) {
            push @where, "level = " . $self->_quote_string($valid_level);
        }
    }

    # Time range filter on timestamp
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

    # Query patterns directly from logs table for real-time results
    # Pattern extraction uses same logic as MV
    my $sql = qq{
        SELECT
            toString(cityHash64(
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
            )) as pattern_hash,
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
            formatDateTime(min(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' as first_seen,
            formatDateTime(max(timestamp), '%Y-%m-%dT%H:%i:%S') || 'Z' as last_seen,
            count() as count
        FROM ${db}.${table}
        $where_sql
        GROUP BY pattern_hash, pattern, service, level
        ORDER BY count DESC
        LIMIT $limit
    };

    my $results = $self->_query_json($sql, no_cache => 1);

    # Ensure pattern_hash is string (avoid JS BigInt issues)
    for my $row (@$results) {
        $row->{pattern_hash} = "$row->{pattern_hash}";
    }

    return $results;
}

# Get logs matching a specific pattern hash
sub get_pattern_logs {
    my ($self, $pattern_hash, %params) = @_;

    my $table = $self->database . '.' . $self->table;
    my $db = $self->database;

    # Validate pattern_hash (must be a number)
    return { hits => [], total => 0 }
        unless $pattern_hash && $pattern_hash =~ /^\d+$/;

    my $limit = $self->_validate_int($params{limit}, 1, 500) // 100;
    my @where;

    # Time range filter
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

    my $where_sql = @where ? 'AND ' . join(' AND ', @where) : '';

    # Use the same pattern extraction logic as the MV
    my $sql = qq{
        SELECT
            toString(id) as id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts,
            level, service, host, message, raw, meta as meta_json,
            trace_id, request_id
        FROM $table
        WHERE cityHash64(
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
        ) = $pattern_hash
        $where_sql
        ORDER BY timestamp DESC
        LIMIT $limit
    };

    my $results = $self->_query_json($sql, no_cache => 1);

    # Process results
    for my $row (@$results) {
        $row->{timestamp} = delete $row->{ts};
        $row->{meta} = eval { $self->_json->decode($row->{meta_json} // '{}') } // {};
        delete $row->{meta_json};
    }

    return {
        hits  => $results,
        total => scalar @$results,
    };
}

# Get pattern statistics (for dashboard)
sub get_pattern_stats {
    my ($self, %params) = @_;

    my $db = $self->database;

    # Get total unique patterns
    my $sql = qq{
        SELECT
            count(DISTINCT pattern_hash) as unique_patterns,
            count(DISTINCT service) as unique_services,
            count(DISTINCT level) as unique_levels,
            sum(occurrence_count) as total_logs
        FROM ${db}.log_patterns FINAL
    };

    my $result = $self->_query_json($sql, no_cache => 1);

    return $result->[0] // {
        unique_patterns => 0,
        unique_services => 0,
        unique_levels   => 0,
        total_logs      => 0,
    };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Patterns - Log pattern analysis role

=head1 DESCRIPTION

This role provides methods for analyzing and grouping logs by patterns.
Patterns are created by replacing variable parts (UUIDs, IPs, numbers, etc.)
with placeholders, allowing similar logs to be grouped together.

=head1 METHODS

=over 4

=item get_patterns(%params)

Returns top patterns sorted by occurrence count.

=item get_pattern_logs($pattern_hash, %params)

Returns logs matching a specific pattern hash.

=item get_pattern_stats(%params)

Returns pattern statistics for the dashboard.

=back

=cut

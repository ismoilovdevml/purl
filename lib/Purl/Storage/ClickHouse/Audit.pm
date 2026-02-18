package Purl::Storage::ClickHouse::Audit;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Audit Log Operations
# ============================================

sub _init_audit_schema {
    my ($self) = @_;
    my $db = $self->database;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.audit_logs (
            id UUID DEFAULT generateUUIDv4(),
            timestamp DateTime64(3, 'UTC') DEFAULT now64(),
            actor LowCardinality(String),
            action LowCardinality(String),
            resource_type LowCardinality(String),
            resource_id String,
            details String DEFAULT '',
            ip_address String DEFAULT '',
            status LowCardinality(String) DEFAULT 'success'
        ) ENGINE = @{[$self->_engine_mergetree('audit_logs')]}
        ORDER BY (timestamp, actor)
        TTL toDateTime(timestamp) + INTERVAL 90 DAY
        SETTINGS index_granularity = 8192
    });
}

sub log_audit_event {
    my ($self, $params) = @_;
    my $db = $self->database;

    my $actor         = $params->{actor}         // 'unknown';
    my $action        = $params->{action}         // 'unknown';
    my $resource_type = $params->{resource_type}  // '';
    my $resource_id   = $params->{resource_id}    // '';
    my $details       = $params->{details}        // '';
    my $ip_address    = $params->{ip_address}     // '';
    my $status        = $params->{status}         // 'success';

    $status = 'success' unless $status =~ /^(success|failure)$/;

    eval {
        $self->_query(qq{
            INSERT INTO ${db}.audit_logs
                (actor, action, resource_type, resource_id, details, ip_address, status)
            VALUES (
                @{[$self->_quote_string($actor)]},
                @{[$self->_quote_string($action)]},
                @{[$self->_quote_string($resource_type)]},
                @{[$self->_quote_string($resource_id)]},
                @{[$self->_quote_string($details)]},
                @{[$self->_quote_string($ip_address)]},
                @{[$self->_quote_string($status)]}
            )
        });
    };
    # Fire-and-forget: ignore errors so audit failures never break the app
}

sub get_audit_logs {
    my ($self, $params) = @_;
    my $db = $self->database;

    $params //= {};

    my $limit  = int($params->{limit}  // 100);
    my $offset = int($params->{offset} // 0);
    $limit  = 500 if $limit  > 500;
    $limit  = 1   if $limit  < 1;
    $offset = 0   if $offset < 0;

    my @where;
    push @where, "actor = "         . $self->_quote_string($params->{actor})         if $params->{actor};
    push @where, "action = "        . $self->_quote_string($params->{action})        if $params->{action};
    push @where, "resource_type = " . $self->_quote_string($params->{resource_type}) if $params->{resource_type};

    if ($params->{from_ts}) {
        my $from = int($params->{from_ts});
        push @where, "timestamp >= fromUnixTimestamp($from)";
    }
    if ($params->{to_ts}) {
        my $to = int($params->{to_ts});
        push @where, "timestamp <= fromUnixTimestamp($to)";
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';

    return $self->_query_json(qq{
        SELECT
            toString(id)   AS id,
            formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%SZ') AS timestamp,
            actor,
            action,
            resource_type,
            resource_id,
            details,
            ip_address,
            status
        FROM ${db}.audit_logs
        $where_sql
        ORDER BY timestamp DESC
        LIMIT $limit
        OFFSET $offset
    }, no_cache => 1);
}

sub get_audit_stats {
    my ($self) = @_;
    my $db = $self->database;

    return $self->_query_json(qq{
        SELECT action, status, count() AS count
        FROM ${db}.audit_logs
        WHERE timestamp >= now() - INTERVAL 24 HOUR
        GROUP BY action, status
        ORDER BY count DESC
    }, no_cache => 1);
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Audit - Audit log storage role

=head1 DESCRIPTION

Provides ClickHouse storage operations for the audit log system.
Events are stored with 90-day TTL and fire-and-forget insertion
so audit failures never interrupt normal request handling.

=cut

package Purl::Storage::ClickHouse::Agents;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Agent Management Operations
# ============================================

sub _init_agents_schema {
    my ($self) = @_;
    my $db = $self->database;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.agents (
            id UUID DEFAULT generateUUIDv4(),
            hostname String,
            os String DEFAULT '',
            ip_address String DEFAULT '',
            agent_version String DEFAULT '',
            api_key_label String DEFAULT '',
            labels String DEFAULT '{}',
            registered_at DateTime64(3, 'UTC') DEFAULT now64(),
            last_heartbeat DateTime64(3, 'UTC') DEFAULT now64()
        ) ENGINE = ReplacingMergeTree(last_heartbeat)
        ORDER BY (hostname, ip_address)
        SETTINGS index_granularity = 8192
    });
}

sub register_agent {
    my ($self, $params) = @_;
    my $db = $self->database;

    my $hostname      = $params->{hostname}      // '';
    my $os            = $params->{os}            // '';
    my $ip_address    = $params->{ip_address}    // '';
    my $agent_version = $params->{agent_version} // '';
    my $api_key_label = $params->{api_key_label} // '';
    my $labels        = $params->{labels}        // '{}';

    $self->_query(qq{
        INSERT INTO ${db}.agents
            (hostname, os, ip_address, agent_version, api_key_label, labels)
        VALUES (
            @{[$self->_quote_string($hostname)]},
            @{[$self->_quote_string($os)]},
            @{[$self->_quote_string($ip_address)]},
            @{[$self->_quote_string($agent_version)]},
            @{[$self->_quote_string($api_key_label)]},
            @{[$self->_quote_string($labels)]}
        )
    });
}

sub heartbeat_agent {
    my ($self, $params) = @_;
    my $db = $self->database;

    my $hostname      = $params->{hostname}      // '';
    my $ip_address    = $params->{ip_address}    // '';
    my $agent_version = $params->{agent_version} // '';

    # ReplacingMergeTree deduplicates by ORDER BY (hostname, ip_address),
    # keeping the row with the latest last_heartbeat
    $self->_query(qq{
        INSERT INTO ${db}.agents
            (hostname, ip_address, agent_version, last_heartbeat)
        VALUES (
            @{[$self->_quote_string($hostname)]},
            @{[$self->_quote_string($ip_address)]},
            @{[$self->_quote_string($agent_version)]},
            now64()
        )
    });
}

sub get_agents {
    my ($self) = @_;
    my $db = $self->database;

    return $self->_query_json(qq{
        SELECT
            toString(id) AS id,
            hostname,
            os,
            ip_address,
            agent_version,
            api_key_label,
            labels,
            formatDateTime(registered_at, '%Y-%m-%dT%H:%i:%SZ') AS registered_at,
            formatDateTime(last_heartbeat, '%Y-%m-%dT%H:%i:%SZ') AS last_heartbeat,
            if(last_heartbeat >= now() - INTERVAL 2 MINUTE, 'online', 'offline') AS status
        FROM ${db}.agents FINAL
        ORDER BY last_heartbeat DESC
    }, no_cache => 1);
}

sub count_agents {
    my ($self) = @_;
    my $db = $self->database;

    my $result = $self->_query_json(qq{
        SELECT count() AS total_count
        FROM ${db}.agents FINAL
    }, no_cache => 1);

    return ($result && @$result) ? $result->[0]{total_count} : 0;
}

sub delete_agent {
    my ($self, $id) = @_;
    my $db = $self->database;

    $self->_query(qq{
        ALTER TABLE ${db}.agents DELETE
        WHERE toString(id) = @{[$self->_quote_string($id)]}
    });
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Agents - Agent management storage role

=head1 DESCRIPTION

Provides ClickHouse storage operations for managing Purl log collection agents.
Uses ReplacingMergeTree to automatically deduplicate agent records by hostname
and IP address, keeping only the most recent heartbeat.

=cut

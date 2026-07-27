package Purl::Storage::ClickHouse::Alerts;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# ============================================
# Re-notify suppression
# ============================================

# True when this alert fired recently enough that notifying again would be a
# duplicate rather than a new incident.
#
# check_alerts() counts rows inside a rolling window, so the SAME incident stays
# above threshold for the whole window. Before the server-side scheduler existed
# this only mattered while a dashboard tab was open; now a timer evaluates every
# 60s, so a 5-minute window would send five Telegram messages for one incident,
# and sustained errors would notify forever.
#
# The cooldown is the alert's own window: one notification per window per alert.
# last_triggered = 0 (never fired) always notifies.
sub alert_in_cooldown {
    my ($alert) = @_;

    my $last = $alert->{last_triggered_ts} or return 0;
    my $now  = $alert->{now_ts}            or return 0;

    my $window = $alert->{window_minutes};
    $window = 5 unless defined $window && $window =~ /^\d+$/ && $window > 0;

    return ($now - $last) < ($window * 60) ? 1 : 0;
}

# ============================================
# Alerts CRUD Operations
# ============================================

sub get_alerts {
    my ($self) = @_;
    my $db = $self->database;
    return $self->_query_json(qq{
        SELECT toString(id) as id, name, query, condition, threshold, window_minutes,
               notify_type, notify_target, enabled,
               formatDateTime(last_triggered, '%Y-%m-%dT%H:%i:%SZ') as last_triggered,
               formatDateTime(created_at, '%Y-%m-%dT%H:%i:%SZ') as created_at
        FROM ${db}.alerts
        ORDER BY created_at DESC
    });
}

sub create_alert {
    my ($self, %params) = @_;
    my $db = $self->database;

    my $name = $params{name} // 'Unnamed Alert';
    my $query = $params{query} // '';
    my $condition = $params{condition} // 'count';
    my $threshold = $self->_validate_int($params{threshold}, 1, 1000000) // 10;
    my $window = $self->_validate_int($params{window_minutes}, 1, 1440) // 5;
    my $notify_type = $params{notify_type} // 'webhook';
    my $notify_target = $params{notify_target} // '';

    # Validate notify_type (whitelist)
    $notify_type = 'webhook' unless $notify_type =~ /^(telegram|slack|webhook)$/;

    $self->_query(qq{
        INSERT INTO ${db}.alerts (name, query, condition, threshold, window_minutes, notify_type, notify_target)
        VALUES (@{[$self->_quote_string($name)]}, @{[$self->_quote_string($query)]}, @{[$self->_quote_string($condition)]}, $threshold, $window, @{[$self->_quote_string($notify_type)]}, @{[$self->_quote_string($notify_target)]})
    });
    return 1;
}

sub update_alert {
    my ($self, $id, %params) = @_;
    my $db = $self->database;

    # Validate UUID format
    return 0 unless $self->_validate_uuid($id);

    my @updates;
    for my $key (qw(name query condition notify_target)) {
        if (exists $params{$key}) {
            push @updates, "$key = " . $self->_quote_string($params{$key});
        }
    }
    # Validate notify_type
    if (exists $params{notify_type}) {
        my $nt = $params{notify_type};
        $nt = 'webhook' unless $nt =~ /^(telegram|slack|webhook)$/;
        push @updates, "notify_type = " . $self->_quote_string($nt);
    }
    # Validate numeric fields
    if (exists $params{threshold}) {
        my $val = $self->_validate_int($params{threshold}, 1, 1000000);
        push @updates, "threshold = $val" if defined $val;
    }
    if (exists $params{window_minutes}) {
        my $val = $self->_validate_int($params{window_minutes}, 1, 1440);
        push @updates, "window_minutes = $val" if defined $val;
    }
    if (exists $params{enabled}) {
        my $val = $params{enabled} ? 1 : 0;
        push @updates, "enabled = $val";
    }

    return 0 unless @updates;

    my $set_clause = join(', ', @updates);
    $self->_query(qq{
        ALTER TABLE ${db}.alerts UPDATE $set_clause WHERE id = @{[$self->_quote_string($id)]}
    });
    return 1;
}

sub delete_alert {
    my ($self, $id) = @_;
    my $db = $self->database;

    # Validate UUID format
    return 0 unless $self->_validate_uuid($id);

    $self->_query(qq{
        ALTER TABLE ${db}.alerts DELETE WHERE id = @{[$self->_quote_string($id)]}
    });
    return 1;
}

sub check_alerts {
    my ($self) = @_;
    my $db = $self->database;
    my $table = $self->database . '.' . $self->table;

    my $alerts = $self->_query_json(qq{
        SELECT toString(id) as id, name, query, condition, threshold, window_minutes,
               notify_type, notify_target,
               toUnixTimestamp(last_triggered) as last_triggered_ts,
               toUnixTimestamp(now()) as now_ts
        FROM ${db}.alerts
        WHERE enabled = 1
    });

    return [] unless @$alerts;

    # Group alerts by window_minutes for batch querying
    my %by_window;
    for my $alert (@$alerts) {
        my $window = $self->_validate_int($alert->{window_minutes}, 1, 1440) // 5;
        push @{$by_window{$window}}, $alert;
    }

    my @triggered;
    my @triggered_ids;

    # Process each window group with a single optimized query
    for my $window (keys %by_window) {
        my $window_alerts = $by_window{$window};

        # Build UNION ALL query for all alerts in this window
        my @case_conditions;
        my %alert_by_id;

        for my $alert (@$window_alerts) {
            $alert_by_id{$alert->{id}} = $alert;
            my $query_filter = $alert->{query};
            my $alert_id_quoted = $self->_quote_string($alert->{id});

            my $filter_condition = '1=1';
            if ($query_filter) {
                if ($query_filter =~ /^level:(\w+)$/i) {
                    my $level = $self->_validate_level($1);
                    $filter_condition = "level = " . $self->_quote_string($level) if $level;
                } elsif ($query_filter =~ /^service:(\S+)$/i) {
                    my $service = $self->_sanitize_identifier($1);
                    $filter_condition = "service = " . $self->_quote_string($service) if $service;
                } else {
                    $filter_condition = "position(message, " . $self->_quote_string($query_filter) . ") > 0";
                }
            }

            push @case_conditions, qq{
                SELECT $alert_id_quoted as alert_id, count() as cnt
                FROM $table
                WHERE timestamp >= now() - INTERVAL $window MINUTE
                  AND $filter_condition
            };
        }

        # Execute single query for all alerts in this window
        my $combined_sql = join("\nUNION ALL\n", @case_conditions);
        my $results = $self->_query_json($combined_sql);

        # Check thresholds
        for my $row (@$results) {
            my $alert_id = $row->{alert_id};
            my $count = $row->{cnt} // 0;
            my $alert = $alert_by_id{$alert_id};

            next unless $alert && $count >= $alert->{threshold};
            next if alert_in_cooldown($alert);

            push @triggered, {
                %$alert,
                count => $count,
            };
            push @triggered_ids, $alert_id if $self->_validate_uuid($alert_id);
        }
    }

    # Batch update last_triggered for all triggered alerts
    if (@triggered_ids) {
        my $ids_str = join(', ', map { $self->_quote_string($_) } @triggered_ids);
        $self->_query(qq{
            ALTER TABLE ${db}.alerts UPDATE last_triggered = now() WHERE id IN ($ids_str)
        });
    }

    return \@triggered;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Alerts - Alerts CRUD operations role

=head1 DESCRIPTION

This role provides CRUD operations for managing alerts in ClickHouse.

=cut

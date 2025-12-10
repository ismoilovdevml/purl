package Purl::Storage::ClickHouse::Alerts;
use strict;
use warnings;
use 5.024;

use Moo::Role;

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
               notify_type, notify_target
        FROM ${db}.alerts
        WHERE enabled = 1
    });

    my @triggered;
    for my $alert (@$alerts) {
        my $window = $self->_validate_int($alert->{window_minutes}, 1, 1440) // 5;
        my $query_filter = $alert->{query};

        # Build WHERE clause
        my @where = ("timestamp >= now() - INTERVAL $window MINUTE");
        if ($query_filter) {
            if ($query_filter =~ /^level:(\w+)$/i) {
                my $level = $self->_validate_level($1);
                push @where, "level = " . $self->_quote_string($level) if $level;
            } elsif ($query_filter =~ /^service:(\S+)$/i) {
                my $service = $self->_sanitize_identifier($1);
                push @where, "service = " . $self->_quote_string($service) if $service;
            } else {
                push @where, "position(message, " . $self->_quote_string($query_filter) . ") > 0";
            }
        }

        my $where_sql = join(' AND ', @where);
        my $count_sql = "SELECT count() as cnt FROM $table WHERE $where_sql";
        my $result = $self->_query_json($count_sql);
        my $count = $result->[0]{cnt} // 0;

        if ($count >= $alert->{threshold}) {
            push @triggered, {
                %$alert,
                count => $count,
            };

            # Update last_triggered
            if ($self->_validate_uuid($alert->{id})) {
                $self->_query(qq{
                    ALTER TABLE ${db}.alerts UPDATE last_triggered = now() WHERE id = @{[$self->_quote_string($alert->{id})]}
                });
            }
        }
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

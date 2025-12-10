package Purl::Storage::ClickHouse::Query;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# Allowed field names (whitelist for SQL injection prevention)
my %ALLOWED_FIELDS = map { $_ => 1 } qw(
    level service host timestamp message raw meta
);

# Allowed level values
my %ALLOWED_LEVELS = map { $_ => 1 } qw(
    TRACE DEBUG INFO NOTICE WARNING WARN ERROR CRITICAL ALERT EMERGENCY FATAL
);

# ============================================
# SQL Injection Prevention Helpers
# ============================================

# Escape string for ClickHouse SQL (prevents SQL injection)
sub _quote_string {
    my ($self, $value) = @_;
    return "''" unless defined $value;
    # Escape backslashes first, then single quotes
    $value =~ s/\\/\\\\/g;
    $value =~ s/'/\\'/g;
    return "'$value'";
}

# Validate and sanitize field name (whitelist approach)
sub _validate_field {
    my ($self, $field) = @_;
    return undef unless defined $field;
    $field = lc($field);
    return $ALLOWED_FIELDS{$field} ? $field : undef;
}

# Validate level value
sub _validate_level {
    my ($self, $level) = @_;
    return undef unless defined $level;
    $level = uc($level);
    return $ALLOWED_LEVELS{$level} ? $level : undef;
}

# Sanitize service/host name (alphanumeric, dash, underscore, dot only)
sub _sanitize_identifier {
    my ($self, $value) = @_;
    return undef unless defined $value;
    # Allow wildcards for LIKE queries
    $value =~ s/[^a-zA-Z0-9_\-\.\*]//g;
    return length($value) > 0 ? $value : undef;
}

# Validate integer
sub _validate_int {
    my ($self, $value, $min, $max) = @_;
    return undef unless defined $value && $value =~ /^\d+$/;
    my $num = int($value);
    $num = $min if defined $min && $num < $min;
    $num = $max if defined $max && $num > $max;
    return $num;
}

# Validate order direction
sub _validate_order {
    my ($self, $order) = @_;
    return 'DESC' unless defined $order;
    $order = uc($order);
    return ($order eq 'ASC' || $order eq 'DESC') ? $order : 'DESC';
}

# Validate UUID format
sub _validate_uuid {
    my ($self, $id) = @_;
    return 0 unless $id && $id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    return 1;
}

# Build WHERE clause from parameters
sub _build_where_clause {
    my ($self, %params) = @_;
    my @where;

    # Time range
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

    # Level filter
    if ($params{level}) {
        if (ref $params{level} eq 'ARRAY') {
            my @valid_levels = grep { defined } map { $self->_validate_level($_) } @{$params{level}};
            if (@valid_levels) {
                my $levels = join(',', map { $self->_quote_string($_) } @valid_levels);
                push @where, "level IN ($levels)";
            }
        } else {
            my $valid_level = $self->_validate_level($params{level});
            if ($valid_level) {
                push @where, "level = " . $self->_quote_string($valid_level);
            }
        }
    }

    # Service filter
    if ($params{service}) {
        my $service = $self->_sanitize_identifier($params{service});
        if ($service) {
            if ($service =~ /\*/) {
                my $pattern = $service;
                $pattern =~ s/\*/%/g;
                push @where, "service LIKE " . $self->_quote_string($pattern);
            } else {
                push @where, "service = " . $self->_quote_string($service);
            }
        }
    }

    # Host filter
    if ($params{host}) {
        my $host = $self->_sanitize_identifier($params{host});
        if ($host) {
            push @where, "host = " . $self->_quote_string($host);
        }
    }

    # Full-text search
    if ($params{query}) {
        push @where, "position(message, " . $self->_quote_string($params{query}) . ") > 0";
    }

    return @where ? 'WHERE ' . join(' AND ', @where) : '';
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Query - SQL query building and sanitization role

=head1 DESCRIPTION

This role provides methods for building safe SQL queries with proper
input validation and SQL injection prevention.

=cut

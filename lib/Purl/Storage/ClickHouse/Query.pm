package Purl::Storage::ClickHouse::Query;
use strict;
use warnings;
use 5.024;

use Moo::Role;

# Allowed field names (whitelist for SQL injection prevention)
my %ALLOWED_FIELDS = map { $_ => 1 } qw(
    level service host timestamp message raw meta
    trace_id request_id span_id parent_span_id
);

# Allowed meta sub-fields for K8s support
my %ALLOWED_META_FIELDS = map { $_ => 1 } qw(
    namespace pod container node cluster source
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

    # Check for meta.* fields (K8s support)
    if ($field =~ /^meta\.(\w+)$/) {
        my $sub_field = $1;
        return $ALLOWED_META_FIELDS{$sub_field} ? $field : undef;
    }

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

# Sanitize trace/request ID (alphanumeric, dash only, 8-36 chars)
sub _sanitize_trace_id {
    my ($self, $value) = @_;
    return undef unless defined $value;
    # Only allow hex characters and dashes (common formats: UUID, W3C trace-id)
    $value =~ s/[^a-fA-F0-9\-]//g;
    return (length($value) >= 8 && length($value) <= 36) ? lc($value) : undef;
}

# Build WHERE clause from parameters
sub _build_where_clause {
    my ($self, %params) = @_;
    my @where;
    my %bind_params;

    # Time range
    if ($params{from}) {
        my $from_ts = $self->_convert_to_clickhouse_ts($params{from});
        if ($from_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp >= {p_from:DateTime64(3)}";
            $bind_params{p_from} = $from_ts;
        }
    }
    if ($params{to}) {
        my $to_ts = $self->_convert_to_clickhouse_ts($params{to});
        if ($to_ts =~ /^[\d\-: \.]+$/) {
            push @where, "timestamp <= {p_to:DateTime64(3)}";
            $bind_params{p_to} = $to_ts;
        }
    }

    # Level filter
    if ($params{level}) {
        if (ref $params{level} eq 'ARRAY') {
            my @valid_levels = grep { defined } map { $self->_validate_level($_) } @{$params{level}};
            if (@valid_levels) {
                # ClickHouse doesn't support array parameters in IN clause easily via HTTP API in older versions
                # checking if we can use an array param or just multiple ORs or separate params
                # For safety and simple HTTP API compatibility, let's use creating multiple params
                my @level_placeholders;
                for my $i (0 .. $#valid_levels) {
                    my $pname = "p_level_$i";
                    push @level_placeholders, "{${pname}:String}";
                    $bind_params{$pname} = $valid_levels[$i];
                }
                push @where, "level IN (" . join(', ', @level_placeholders) . ")";
            }
        } else {
            my $valid_level = $self->_validate_level($params{level});
            if ($valid_level) {
                push @where, "level = {p_level:String}";
                $bind_params{p_level} = $valid_level;
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
                push @where, "service LIKE {p_service_pattern:String}";
                $bind_params{p_service_pattern} = $pattern;
            } else {
                push @where, "service = {p_service:String}";
                $bind_params{p_service} = $service;
            }
        }
    }

    # Host filter
    if ($params{host}) {
        my $host = $self->_sanitize_identifier($params{host});
        if ($host) {
            push @where, "host = {p_host:String}";
            $bind_params{p_host} = $host;
        }
    }

    # Full-text search
    if ($params{query}) {
        push @where, "position(message, {p_query:String}) > 0";
        $bind_params{p_query} = $params{query};
    }

    # Trace ID filter
    if ($params{trace_id}) {
        my $trace_id = $self->_sanitize_trace_id($params{trace_id});
        if ($trace_id) {
            push @where, "trace_id = {p_trace_id:String}";
            $bind_params{p_trace_id} = $trace_id;
        }
    }

    # Request ID filter
    if ($params{request_id}) {
        my $request_id = $self->_sanitize_trace_id($params{request_id});
        if ($request_id) {
            push @where, "request_id = {p_request_id:String}";
            $bind_params{p_request_id} = $request_id;
        }
    }

    # Span ID filter
    if ($params{span_id}) {
        my $span_id = $self->_sanitize_trace_id($params{span_id});
        if ($span_id) {
            push @where, "span_id = {p_span_id:String}";
            $bind_params{p_span_id} = $span_id;
        }
    }

    my $where_sql = @where ? 'WHERE ' . join(' AND ', @where) : '';
    return ($where_sql, \%bind_params);
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Query - SQL query building and sanitization role

=head1 DESCRIPTION

This role provides methods for building safe SQL queries with proper
input validation and SQL injection prevention.

=cut

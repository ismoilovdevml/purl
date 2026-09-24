package Purl::Storage::ClickHouse::Query;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Purl::Util::Level qw(canonical_level canonical_levels);
use namespace::clean;

with 'Purl::Storage::ClickHouse::Levels';

# Allowed field names (whitelist for SQL injection prevention)
my %ALLOWED_FIELDS = map { $_ => 1 } qw(
    level service host timestamp message raw meta
    trace_id request_id span_id parent_span_id
    namespace pod container
);

# Allowed meta sub-fields for K8s support
my %ALLOWED_META_FIELDS = map { $_ => 1 } qw(
    namespace pod container node cluster source
    deployment team environment version unit
);

# Allowed level values: the canonical names. A synonym (WARNING, CRIT, ...) is
# accepted and validated as its canonical name (#110).
my %ALLOWED_LEVELS = map { $_ => 1 } canonical_levels();

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
        # Accept whitelisted K8s fields or any lowercase alphanumeric field (max 32 chars)
        return $field if $ALLOWED_META_FIELDS{$sub_field};
        return $field if $sub_field =~ /^[a-z][a-z0-9_]{0,31}$/;
        return undef;
    }

    return $ALLOWED_FIELDS{$field} ? $field : undef;
}

# Validate level value; returns its canonical name
sub _validate_level {
    my ($self, $level) = @_;
    return undef unless defined $level;
    $level = canonical_level($level);
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

# Equality (or LIKE for an unquoted `*`) on a materialised k8s column
# (K8sColumns, #108): 1 byte/row instead of the whole meta string, and it
# matches the KEY's value, not the value text anywhere in meta (cluster=prod
# used to match pod "prod-db"). $column must already be a known k8s column.
sub _k8s_column_sql {
    my ($self, $column, $value, $bind, $pname) = @_;
    if ($value =~ /\*/) {
        (my $pattern = $value) =~ s/([\\%_])/\\$1/g;
        $pattern =~ s/\*/%/g;
        $bind->{$pname} = $pattern;
        return "$column LIKE {${pname}:String}";
    }
    $bind->{$pname} = $value;
    return "$column = {${pname}:String}";
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

    # Range shorthand (e.g., '15m', '1h', '24h', '7d') — used by dashboard widgets
    if ($params{range} && !$params{from}) {
        my $range = $params{range};
        if ($range =~ /^(\d+)([mhd])$/i) {
            my ($num, $unit) = ($1, lc($2));
            my $seconds = $num * ($unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : 86400);
            push @where, "timestamp >= now() - toIntervalSecond($seconds)";
        }
    }

    # Level filter: one level or a list. Every case and synonym older rows may
    # carry (#105, #110) — `level` is a sort key, so they cannot be rewritten.
    if ($params{level}) {
        my @requested = ref $params{level} eq 'ARRAY' ? @{$params{level}} : ($params{level});
        my @valid_levels = grep { defined } map { $self->_validate_level($_) } @requested;
        my $n = 0;
        my $level_sql = $self->_level_filter_sql(\@valid_levels, sub {
            my $name = 'p_level_' . $n++;
            $bind_params{$name} = $_[0];
            return "{${name}:String}";
        });
        push @where, $level_sql if $level_sql;
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

    # KQL boolean expression (AST from Purl::Util::KQL, compiled by the
    # ClickHouse::KQL role). Emitted as ONE parenthesised fragment so it is
    # ANDed with the flat filters instead of leaking its own OR/NOT into them.
    if ($params{kql}) {
        my $seq = 0;
        my $kql_sql = $self->_kql_to_sql($params{kql}, \%bind_params, \$seq);
        push @where, $kql_sql if defined $kql_sql && length $kql_sql;
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

    # Meta field filter (K8s: namespace, pod, node, container, cluster)
    # Use simple position() to find field and value in meta JSON string
    if ($params{meta_field} && $params{meta_value}) {
        my $meta_field = lc($params{meta_field});
        if ($self->can('is_k8s_column') && $self->is_k8s_column($meta_field)) {
            push @where, $self->_k8s_column_sql($meta_field, $params{meta_value}, \%bind_params, 'p_meta_value');
        }
        elsif ($ALLOWED_META_FIELDS{$meta_field} || $meta_field =~ /^[a-z][a-z0-9_]{0,31}$/) {
            my $meta_value = $params{meta_value};
            if ($meta_value =~ /\*/) {
                # Wildcard search - look for field name and partial value
                my $clean_value = $meta_value;
                $clean_value =~ s/\*//g;
                push @where, "(position(meta, {p_meta_field:String}) > 0 AND position(meta, {p_meta_value:String}) > 0)";
                $bind_params{p_meta_field} = $meta_field;
                $bind_params{p_meta_value} = $clean_value;
            } else {
                # Exact match: search for both field name and value in meta
                push @where, "(position(meta, {p_meta_field:String}) > 0 AND position(meta, {p_meta_value:String}) > 0)";
                $bind_params{p_meta_field} = $meta_field;
                $bind_params{p_meta_value} = $meta_value;
            }
        }
    }

    # Kubernetes pickers (#112): cluster/namespace/pod/container as their own
    # filters, ANDed with the whole search expression. Appending them to the
    # query text instead made `a OR b cluster:x` mean `a OR (b AND cluster:x)`.
    for my $column (qw(cluster namespace pod container)) {
        my $value = $params{$column};
        next unless defined $value && length $value && !ref $value;
        next unless $self->can('is_k8s_column') && $self->is_k8s_column($column);
        push @where, $self->_k8s_column_sql($column, $value, \%bind_params, "p_k8s_$column");
    }

    # Namespace scope enforcement (RBAC)
    if ($params{_allowed_namespaces} && ref $params{_allowed_namespaces} eq 'ARRAY') {
        my @ns_list = @{$params{_allowed_namespaces}};
        if (@ns_list) {
            # The materialised namespace column (#104, #108): exact, and 1 byte/row
            # instead of a substring scan of every row's meta.
            my @placeholders;
            for my $i (0 .. $#ns_list) {
                my $pname = "p_ns_$i";
                push @placeholders, "{${pname}:String}";
                $bind_params{$pname} = $ns_list[$i];
            }
            push @where, 'namespace IN (' . join(', ', @placeholders) . ')';
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

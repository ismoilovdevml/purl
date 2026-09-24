package Purl::Storage::ClickHouse::K8sHealth;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# K8s Pod Health Detection (log-based)
# Queries the logs table for known K8s error patterns
# and aggregates by pod/namespace.
# ============================================

# Error pattern definitions for K8s pod health detection
my %ERROR_PATTERNS = (
    crash_loop => {
        label   => 'CrashLoopBackOff',
        strings => ['Back-off restarting failed container', 'CrashLoopBackOff'],
    },
    oom_killed => {
        label   => 'OOMKilled',
        strings => ['OOMKilled', 'out of memory'],
    },
    image_pull => {
        label   => 'ImagePullBackOff',
        strings => ['Failed to pull image', 'ImagePullBackOff', 'ErrImagePull'],
    },
    eviction => {
        label   => 'Evicted',
        strings => ['evicted'],
    },
    node_not_ready => {
        label   => 'NodeNotReady',
        strings => ['NodeNotReady', 'node is not ready'],
    },
);

sub get_unhealthy_pods {
    my ($self, $params) = @_;
    $params //= {};
    my $db = $self->database;

    my $hours = int($params->{hours} // 1);
    $hours = 1  if $hours < 1;
    $hours = 72 if $hours > 72;

    my $limit = int($params->{limit} // 100);
    $limit = 1   if $limit < 1;
    $limit = 500 if $limit > 500;

    # Build OR conditions for all error patterns
    # Each pattern gets a CASE expression that labels it
    my @case_parts;
    my %bind_params;
    my @or_conditions;
    my $idx = 0;

    for my $type (sort keys %ERROR_PATTERNS) {
        my $pattern = $ERROR_PATTERNS{$type};
        for my $str (@{$pattern->{strings}}) {
            my $pname = "p_pat_$idx";
            push @or_conditions, "position(message, {${pname}:String}) > 0";
            $bind_params{$pname} = $str;
            $idx++;
        }
    }

    # Build CASE WHEN for error_type classification
    my @case_whens;
    my $cidx = 0;
    for my $type (sort keys %ERROR_PATTERNS) {
        my $pattern = $ERROR_PATTERNS{$type};
        my @type_conds;
        for my $str (@{$pattern->{strings}}) {
            my $pname = "p_cls_$cidx";
            push @type_conds, "position(message, {${pname}:String}) > 0";
            $bind_params{$pname} = $str;
            $cidx++;
        }
        my $label_pname = "p_lbl_$type";
        $bind_params{$label_pname} = $pattern->{label};
        push @case_whens, "WHEN " . join(' OR ', @type_conds) .
            " THEN {${label_pname}:String}";
    }

    my $case_expr = "CASE " . join("\n            ", @case_whens) . "\n            ELSE 'Unknown' END";

    my $or_clause = join(' OR ', @or_conditions);

    # Namespace filter
    my $ns_filter = '';
    if ($params->{namespace}) {
        my $ns = $params->{namespace};
        $ns =~ s/[^a-zA-Z0-9_\-\.]//g;
        if (length($ns) > 0) {
            $bind_params{p_ns_filter} = $ns;
            $ns_filter = "AND namespace = {p_ns_filter:String}";
        }
    }

    my $sql = qq{
        SELECT
            pod                                   AS pod_name,
            namespace                             AS namespace,
            container                             AS container,
            JSONExtractString(meta, 'node')       AS node,
            $case_expr AS error_type,
            count()                               AS error_count,
            max(timestamp)                        AS last_seen,
            min(timestamp)                        AS first_seen
        FROM ${db}.logs
        WHERE timestamp >= now() - INTERVAL $hours HOUR
            AND ($or_clause)
            AND pod != ''
            $ns_filter
        GROUP BY pod_name, namespace, container, node, error_type
        ORDER BY error_count DESC
        LIMIT $limit
    };

    return $self->_query_json($sql, params => \%bind_params, no_cache => 1);
}

# Count distinct pods that emitted ANY K8s log (meta.pod present) in the
# window — regardless of health. Lets the controller distinguish "no K8s
# data ingested" (0 pods) from "K8s data exists and all pods are healthy"
# (>0 pods, but get_pod_health_summary returns no error rows). Returns a
# plain integer.
sub get_k8s_pod_count {
    my ($self, $params) = @_;
    $params //= {};
    my $db = $self->database;

    my $hours = int($params->{hours} // 1);
    $hours = 1  if $hours < 1;
    $hours = 72 if $hours > 72;

    my $sql = qq{
        SELECT uniqExact(pod) AS pod_count
        FROM ${db}.logs
        WHERE timestamp >= now() - INTERVAL $hours HOUR
            AND pod != ''
    };

    my $rows = $self->_query_json($sql, no_cache => 1);
    return int($rows->[0]{pod_count} // 0);
}

sub get_pod_health_summary {
    my ($self, $params) = @_;
    $params //= {};
    my $db = $self->database;

    my $hours = int($params->{hours} // 1);
    $hours = 1  if $hours < 1;
    $hours = 72 if $hours > 72;

    # Build CASE and OR for summary counts
    my %bind_params;
    my @or_conditions;
    my @case_whens;
    my $idx = 0;
    my $cidx = 0;

    for my $type (sort keys %ERROR_PATTERNS) {
        my $pattern = $ERROR_PATTERNS{$type};
        my @type_conds;
        for my $str (@{$pattern->{strings}}) {
            my $or_pname = "p_sor_$idx";
            push @or_conditions, "position(message, {${or_pname}:String}) > 0";
            $bind_params{$or_pname} = $str;
            $idx++;

            my $cls_pname = "p_scl_$cidx";
            push @type_conds, "position(message, {${cls_pname}:String}) > 0";
            $bind_params{$cls_pname} = $str;
            $cidx++;
        }
        my $label_pname = "p_slbl_$type";
        $bind_params{$label_pname} = $pattern->{label};
        push @case_whens, "WHEN " . join(' OR ', @type_conds) .
            " THEN {${label_pname}:String}";
    }

    my $case_expr = "CASE " . join("\n            ", @case_whens) . "\n            ELSE 'Unknown' END";
    my $or_clause = join(' OR ', @or_conditions);

    my $sql = qq{
        SELECT
            $case_expr AS error_type,
            uniqExact(pod) AS pod_count,
            count() AS total_errors
        FROM ${db}.logs
        WHERE timestamp >= now() - INTERVAL $hours HOUR
            AND ($or_clause)
            AND pod != ''
        GROUP BY error_type
        ORDER BY total_errors DESC
    };

    return $self->_query_json($sql, params => \%bind_params, no_cache => 1);
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::K8sHealth - K8s pod health detection via log analysis

=head1 DESCRIPTION

Moo::Role that provides methods for detecting unhealthy Kubernetes pods
by scanning log messages for known error patterns (CrashLoopBackOff,
OOMKilled, ImagePullBackOff, Eviction, NodeNotReady).

=cut

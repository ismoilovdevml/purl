package Purl::API::Controller::AlertTemplates;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

extends 'Purl::API::Controller::Base';

# ============================================
# Predefined K8s alert templates (hardcoded)
# ============================================

my @TEMPLATES = (
    {
        id             => 'k8s-crashloop',
        name           => 'Pod CrashLoopBackOff',
        description    => 'Detects pods stuck in CrashLoopBackOff restart loop',
        category       => 'kubernetes',
        severity       => 'critical',
        query          => '"Back-off restarting failed container" OR CrashLoopBackOff',
        threshold      => 3,
        window_minutes => 10,
    },
    {
        id             => 'k8s-oom',
        name           => 'OOMKilled Events',
        description    => 'Detects pods killed due to out of memory',
        category       => 'kubernetes',
        severity       => 'critical',
        query          => 'OOMKilled OR "out of memory"',
        threshold      => 1,
        window_minutes => 5,
    },
    {
        id             => 'k8s-imagepull',
        name           => 'ImagePullBackOff',
        description    => 'Detects failed image pulls',
        category       => 'kubernetes',
        severity       => 'warning',
        query          => '"Failed to pull image" OR ImagePullBackOff OR ErrImagePull',
        threshold      => 2,
        window_minutes => 10,
    },
    {
        id             => 'k8s-eviction',
        name           => 'Pod Eviction',
        description    => 'Detects pod eviction events',
        category       => 'kubernetes',
        severity       => 'warning',
        query          => '"evicted" AND meta.source:k8s-audit',
        threshold      => 1,
        window_minutes => 15,
    },
    {
        id             => 'k8s-error-rate',
        name           => 'High Error Rate per Namespace',
        description    => 'Detects high error rates within a namespace',
        category       => 'kubernetes',
        severity       => 'warning',
        query          => 'level:ERROR',
        threshold      => 100,
        window_minutes => 5,
    },
    {
        id             => 'k8s-node-notready',
        name           => 'Node Not Ready',
        description    => 'Detects nodes in NotReady state',
        category       => 'kubernetes',
        severity       => 'critical',
        query          => '"NodeNotReady" OR "node is not ready"',
        threshold      => 1,
        window_minutes => 5,
    },
    {
        id             => 'k8s-failed-scheduling',
        name           => 'Failed Pod Scheduling',
        description    => 'Detects pods that cannot be scheduled',
        category       => 'kubernetes',
        severity       => 'warning',
        query          => '"FailedScheduling" OR "Insufficient" OR "no nodes available"',
        threshold      => 3,
        window_minutes => 10,
    },
    {
        id             => 'k8s-volume-mount',
        name           => 'Volume Mount Failure',
        description    => 'Detects persistent volume mount failures',
        category       => 'kubernetes',
        severity       => 'critical',
        query          => '"FailedMount" OR "Unable to attach" OR "Unable to mount"',
        threshold      => 1,
        window_minutes => 5,
    },
);

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        $c->render(json => { templates => \@TEMPLATES });
    });
}

# Accessor for template count (useful for tests)
sub template_count {
    return scalar @TEMPLATES;
}

# Accessor for templates data (useful for tests)
sub templates {
    return \@TEMPLATES;
}

1;

__END__

=head1 NAME

Purl::API::Controller::AlertTemplates - Predefined K8s alert templates

=head1 DESCRIPTION

Returns hardcoded Kubernetes alert templates for common failure scenarios.
Templates are not stored in the database — they are compile-time constants.

Endpoints:
    GET /api/alerts/templates - List all alert templates

=cut

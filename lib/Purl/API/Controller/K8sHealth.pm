package Purl::API::Controller::K8sHealth;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

extends 'Purl::API::Controller::Base';

# ============================================
# K8s Pod Health Visualization Controller
# Provides endpoints for detecting unhealthy pods
# based on log pattern analysis.
# ============================================

sub summary {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'k8s_monitoring');

        my $hours = $c->param('hours') // 1;

        my $rows = $self->storage->get_pod_health_summary({ hours => $hours });

        my %summary;
        my $total_unhealthy = 0;
        for my $row (@$rows) {
            my $type = $row->{error_type} // 'Unknown';
            $summary{$type} = {
                pod_count    => int($row->{pod_count}    // 0),
                total_errors => int($row->{total_errors}  // 0),
            };
            $total_unhealthy += int($row->{pod_count} // 0);
        }

        $c->render(json => {
            summary         => \%summary,
            total_unhealthy => $total_unhealthy,
            hours           => int($hours),
        });
    });
}

sub pods {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'k8s_monitoring');

        my $hours     = $c->param('hours')     // 1;
        my $limit     = $c->param('limit')     // 100;
        my $namespace = $c->param('namespace');

        my $rows = $self->storage->get_unhealthy_pods({
            hours     => $hours,
            limit     => $limit,
            namespace => $namespace,
        });

        my @pods;
        for my $row (@$rows) {
            push @pods, {
                name        => $row->{pod_name}    // '',
                namespace   => $row->{namespace}   // '',
                container   => $row->{container}   // '',
                node        => $row->{node}        // '',
                error_type  => $row->{error_type}  // 'Unknown',
                count       => int($row->{error_count} // 0),
                last_seen   => $row->{last_seen}   // '',
                first_seen  => $row->{first_seen}  // '',
            };
        }

        $c->render(json => {
            pods  => \@pods,
            total => scalar @pods,
            hours => int($hours),
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::K8sHealth - K8s pod health visualization

=head1 DESCRIPTION

Provides REST endpoints for Kubernetes pod health monitoring
based on log pattern analysis.

Endpoints:
    GET /api/k8s/health      - Pod health summary by error type
    GET /api/k8s/health/pods - Unhealthy pods list with details

=cut

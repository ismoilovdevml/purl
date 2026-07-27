package Purl::API::Controller::Audit;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

extends 'Purl::API::Controller::Base';

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->session('username');
        my $api_key  = $c->req->headers->header('X-API-Key');
        unless ($username || $api_key) {
            $self->render_error($c, 'Unauthorized', 401);
            return;
        }

        # Feature gate first so an unlicensed plan still gets the
        # {feature => 'audit_logs'} 403 body the dashboard renders an upsell
        # from; the role check below then narrows it to admins.
        return unless $self->require_feature($c, 'audit_logs');

        # Audit records every login, source IP and admin action — the exact
        # material an attacker uses for recon, and a privacy exposure for
        # other users. Admin only; a viewer must not see it.
        return unless $self->require_role($c, 'admin');

        my $actor         = $c->param('actor');
        my $action        = $c->param('action');
        my $resource_type = $c->param('resource_type');
        my $from          = $c->param('from');
        my $to            = $c->param('to');
        my $limit         = $c->param('limit')  // 100;
        my $offset        = $c->param('offset') // 0;

        $limit  = 500 if $limit  > 500;
        $limit  = 1   if $limit  < 1;

        my %params = (
            limit  => int($limit),
            offset => int($offset),
        );
        $params{actor}         = $actor         if $actor;
        $params{action}        = $action        if $action;
        $params{resource_type} = $resource_type if $resource_type;
        $params{from_ts}       = int($from)     if $from && $from =~ /^\d+$/;
        $params{to_ts}         = int($to)       if $to   && $to   =~ /^\d+$/;

        my $logs        = $self->storage->get_audit_logs(\%params);
        my $total_count = $self->storage->count_audit_logs(\%params);

        $c->render(json => {
            logs        => $logs,
            total       => scalar(@$logs),
            total_count => int($total_count),
        });
    });
}

sub stats {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->session('username');
        my $api_key  = $c->req->headers->header('X-API-Key');
        unless ($username || $api_key) {
            $self->render_error($c, 'Unauthorized', 401);
            return;
        }

        # Feature gate first so an unlicensed plan still gets the
        # {feature => 'audit_logs'} 403 body the dashboard renders an upsell
        # from; the role check below then narrows it to admins.
        return unless $self->require_feature($c, 'audit_logs');

        # Audit records every login, source IP and admin action — the exact
        # material an attacker uses for recon, and a privacy exposure for
        # other users. Admin only; a viewer must not see it.
        return unless $self->require_role($c, 'admin');

        my $audit_stats = $self->storage->get_audit_stats();
        $c->render(json => { stats => $audit_stats });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Audit - Audit log REST endpoints

=head1 DESCRIPTION

GET /api/audit       - Query audit log events with optional filters
GET /api/audit/stats - Aggregated audit statistics for last 24h

=cut

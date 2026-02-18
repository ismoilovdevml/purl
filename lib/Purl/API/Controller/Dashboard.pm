package Purl::API::Controller::Dashboard;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

extends 'Purl::API::Controller::Base';

# ============================================
# Custom dashboard management API
# ============================================

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $dashboards = $self->storage->list_dashboards();
        $c->render(json => { dashboards => $dashboards });
    });
}

sub get {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid dashboard ID', 400);
            return;
        }

        my $dashboard = $self->storage->get_dashboard($id);
        unless ($dashboard) {
            $self->render_error($c, 'Dashboard not found', 404);
            return;
        }

        $c->render(json => $dashboard);
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        unless ($body->{name} && length($body->{name}) > 0) {
            $self->render_error($c, 'Dashboard name is required', 400);
            return;
        }

        # Validate widgets
        if ($body->{widgets} && ref $body->{widgets} eq 'ARRAY') {
            for my $widget (@{ $body->{widgets} }) {
                unless ($widget->{type} && $widget->{type} =~ /^(counter|chart|table|log_stream)$/) {
                    $self->render_error($c, "Invalid widget type: $widget->{type}", 400);
                    return;
                }
            }
        }

        $body->{owner} = $c->session('username') // '';
        my $result = $self->storage->create_dashboard($body);
        $c->render(json => $result, status => 201);
    });
}

sub update {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid dashboard ID', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $result = $self->storage->update_dashboard($id, $body);
        unless ($result) {
            $self->render_error($c, 'Dashboard not found', 404);
            return;
        }

        $c->render(json => $result);
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid dashboard ID', 400);
            return;
        }

        my $result = $self->storage->delete_dashboard($id);
        $c->render(json => $result);
    });
}

# ============================================
# Dashboard templates (pre-built dashboards)
# ============================================

my @TEMPLATES = (
    {
        id          => 'k8s-overview',
        name        => 'Kubernetes Overview',
        description => 'Cluster-wide overview: namespaces, pods, errors, node health',
        widgets     => [
            { type => 'counter', title => 'Total Logs (24h)',      query => '*',           timeRange => '24h' },
            { type => 'counter', title => 'Errors (24h)',          query => 'level:ERROR', timeRange => '24h' },
            { type => 'chart',   title => 'Logs by Namespace',     query => '*',           groupBy => 'meta.namespace', timeRange => '24h' },
            { type => 'chart',   title => 'Error Rate by Service', query => 'level:ERROR', groupBy => 'service',        timeRange => '6h' },
            { type => 'chart',   title => 'Logs by Node',          query => '*',           groupBy => 'meta.node',      timeRange => '24h' },
            { type => 'table',   title => 'Top Error Pods',        query => 'level:ERROR', groupBy => 'meta.pod',       limit => 10,  timeRange => '24h' },
            { type => 'log_stream', title => 'Recent Errors',      query => 'level:ERROR OR level:FATAL', limit => 20 },
        ],
    },
    {
        id          => 'app-logs',
        name        => 'Application Logs',
        description => 'Service-level log analysis: error rates, top services, recent logs',
        widgets     => [
            { type => 'counter', title => 'Total Logs (1h)',  query => '*',           timeRange => '1h' },
            { type => 'counter', title => 'Errors (1h)',      query => 'level:ERROR', timeRange => '1h' },
            { type => 'chart',   title => 'Logs by Service',  query => '*',           groupBy => 'service', timeRange => '6h' },
            { type => 'chart',   title => 'Errors by Level',  query => 'level:ERROR OR level:WARN OR level:FATAL', groupBy => 'level', timeRange => '6h' },
            { type => 'log_stream', title => 'Recent Logs',   query => '*', limit => 50 },
        ],
    },
    {
        id          => 'security-audit',
        name        => 'Security Audit',
        description => 'Security events: audit logs, auth failures, suspicious activity',
        widgets     => [
            { type => 'counter', title => 'Audit Events (24h)', query => 'service:k8s-audit',                           timeRange => '24h' },
            { type => 'counter', title => 'Auth Failures (24h)', query => 'level:ERROR AND (unauthorized OR forbidden)', timeRange => '24h' },
            { type => 'chart',   title => 'Audit by Verb',      query => 'service:k8s-audit', groupBy => 'meta.verb',   timeRange => '24h' },
            { type => 'log_stream', title => 'Recent Security Events', query => 'service:k8s-audit OR (level:ERROR AND unauthorized)', limit => 30 },
        ],
    },
);

sub list_templates {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my @summaries = map { { id => $_->{id}, name => $_->{name}, description => $_->{description} } } @TEMPLATES;
        $c->render(json => { templates => \@summaries });
    });
}

sub create_from_template {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{template_id}) {
            $self->render_error($c, 'template_id is required', 400);
            return;
        }

        my ($template) = grep { $_->{id} eq $body->{template_id} } @TEMPLATES;
        unless ($template) {
            $self->render_error($c, 'Template not found', 404);
            return;
        }

        my $dashboard = {
            name    => $body->{name} // $template->{name},
            widgets => $template->{widgets},
            owner   => $c->session('username') // '',
        };

        my $result = $self->storage->create_dashboard($dashboard);
        $c->render(json => $result, status => 201);
    });
}

sub execute_widget {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'dashboards');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        unless ($body->{type}) {
            $self->render_error($c, 'Widget type required', 400);
            return;
        }

        my $result = $self->storage->execute_widget_query($body);
        $c->render(json => $result);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Dashboard - Custom dashboard management API

=head1 DESCRIPTION

CRUD operations for custom dashboards with widget execution.

Endpoints:
    GET    /api/dashboards           - List dashboards
    GET    /api/dashboards/:id       - Get dashboard
    POST   /api/dashboards           - Create dashboard
    PUT    /api/dashboards/:id       - Update dashboard
    DELETE /api/dashboards/:id       - Delete dashboard
    POST   /api/dashboards/widget    - Execute widget query

=cut

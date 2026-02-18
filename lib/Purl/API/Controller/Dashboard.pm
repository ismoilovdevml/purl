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

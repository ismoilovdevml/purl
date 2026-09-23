package Purl::API::Controller::Alerts;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

use Purl::Alert::Scheduler;

extends 'Purl::API::Controller::Base';

# Notifiers hash reference passed from Server
has 'notifiers' => (
    is      => 'ro',
    default => sub { {} },
);

# Evaluation engine. The SAME object type the server-side recurring timer
# drives (Server.pm), so the manual endpoint and the background schedule can
# never diverge. Injectable so Server can share one instance.
has 'scheduler' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        return Purl::Alert::Scheduler->new(
            storage   => $self->storage,
            notifiers => $self->notifiers,
        );
    },
);

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $alerts = $self->storage->get_alerts();
        $c->render(json => { alerts => $alerts });
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin', 'operator');

        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name}) {
            $self->render_error($c, 'Name required', 400);
            return;
        }

        # Validate the filter with the SAME rule the search endpoints use, so an
        # alert can never be saved with a filter that fails to parse — which
        # does not 400 anything, it just matches nothing and the alert never
        # fires. This is the gate SavedSearches::create already has; the place
        # where a wrong filter means a MISSED page needs it more.
        my %probe;
        return unless $self->_apply_query($c, \%probe, $body->{query});

        $self->storage->create_alert(%$body);
        $c->audit_event(action => 'create_alert', resource_type => 'alert', resource_id => $body->{name});
        $c->render(json => { status => 'ok' });
    });
}

sub update {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin', 'operator');

        my $id = $c->param('id');
        my $body = eval { decode_json($c->req->body) };

        unless ($id) {
            $self->render_error($c, 'ID required', 400);
            return;
        }

        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        # Same filter gate as create — editing an alert is the other door to
        # the same broken state.
        if (exists $body->{query}) {
            my %probe;
            return unless $self->_apply_query($c, \%probe, $body->{query});
        }

        $self->storage->update_alert($id, %$body);
        $c->audit_event(action => 'update_alert', resource_type => 'alert', resource_id => $id);
        $c->render(json => { status => 'ok' });
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $id = $c->param('id');

        unless ($id) {
            $self->render_error($c, 'ID required', 400);
            return;
        }

        $self->storage->delete_alert($id);
        $c->audit_event(action => 'delete_alert', resource_type => 'alert', resource_id => $id);
        $c->render(json => { status => 'ok' });
    });
}

sub check {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $result = $self->scheduler->run_once();
        $c->render(json => $result);
    });
}

sub test_notification {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type') // 'telegram';

        my $notifiers = $self->notifiers;

        unless ($notifiers->{$type}) {
            $self->render_error($c, "Notifier '$type' not configured", 400);
            return;
        }

        my $result = $notifiers->{$type}->send_test();
        $c->render(json => {
            success => $result ? 1 : 0,
            type    => $type,
        });
    });
}

# Send notifications for a triggered alert.
# Thin delegation kept for existing callers/tests — the ONE implementation
# lives in Purl::Alert::Scheduler so the timer path uses identical logic.
sub _send_notifications {
    my ($self, $alert, $context) = @_;
    return $self->scheduler->send_notifications($alert, $context);
}

1;

__END__

=head1 NAME

Purl::API::Controller::Alerts - Alert management endpoints

=head1 DESCRIPTION

Handles alert CRUD, checking, and notification sending.

=cut

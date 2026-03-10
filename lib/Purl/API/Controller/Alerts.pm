package Purl::API::Controller::Alerts;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Notifiers hash reference passed from Server
has 'notifiers' => (
    is      => 'ro',
    default => sub { {} },
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

        # Enforce alert type feature gating
        my $notify_type = $body->{notify_type} // 'browser';
        if ($notify_type eq 'telegram') {
            return unless $self->require_feature($c, 'telegram_alerts');
        } elsif ($notify_type eq 'slack') {
            return unless $self->require_feature($c, 'slack_alerts');
        } elsif ($notify_type eq 'webhook') {
            return unless $self->require_feature($c, 'webhook_alerts');
        }

        # Enforce alert count limit (count only enabled alerts)
        my $existing = $self->storage->get_alerts();
        my $count = ref $existing eq 'ARRAY'
            ? scalar grep { $_->{enabled} } @$existing
            : 0;
        return unless $self->check_limit($c, 'alerts', $count);

        $self->storage->create_alert(%$body);
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

        # Enforce alert type feature gating on update
        if (my $notify_type = $body->{notify_type}) {
            if ($notify_type eq 'telegram') {
                return unless $self->require_feature($c, 'telegram_alerts');
            } elsif ($notify_type eq 'slack') {
                return unless $self->require_feature($c, 'slack_alerts');
            } elsif ($notify_type eq 'webhook') {
                return unless $self->require_feature($c, 'webhook_alerts');
            }
        }

        $self->storage->update_alert($id, %$body);
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
        $c->render(json => { status => 'ok' });
    });
}

sub check {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $triggered = $self->storage->check_alerts();

        # Send notifications for each triggered alert
        my @notifications;
        for my $alert (@$triggered) {
            my $sent = $self->_send_notifications($alert, { count => $alert->{count} });
            push @notifications, {
                alert => $alert->{name},
                sent  => $sent,
            } if @$sent;
        }

        $c->render(json => {
            triggered     => $triggered,
            notifications => \@notifications,
        });
    });
}

sub test_notification {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type') // 'telegram';

        # Enforce alert type feature gating on test
        if ($type eq 'telegram') {
            return unless $self->require_feature($c, 'telegram_alerts');
        } elsif ($type eq 'slack') {
            return unless $self->require_feature($c, 'slack_alerts');
        } elsif ($type eq 'webhook') {
            return unless $self->require_feature($c, 'webhook_alerts');
        }

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

# Send notifications for a triggered alert
sub _send_notifications {
    my ($self, $alert, $context) = @_;
    my $notifiers = $self->notifiers;

    my @sent;
    my $notify_type = $alert->{notify_type} // 'webhook';

    if ($notify_type eq 'telegram' && $notifiers->{telegram}) {
        if ($notifiers->{telegram}->notify($alert, $context)) {
            push @sent, 'telegram';
        }
    }
    elsif ($notify_type eq 'slack' && $notifiers->{slack}) {
        if ($notifiers->{slack}->notify($alert, $context)) {
            push @sent, 'slack';
        }
    }
    elsif ($notify_type eq 'webhook') {
        if ($alert->{notify_target}) {
            require Purl::Alert::Webhook;
            my $webhook = Purl::Alert::Webhook->new(
                name => 'alert-webhook',
                url  => $alert->{notify_target},
            );
            if ($webhook->notify($alert, $context)) {
                push @sent, 'webhook';
            }
        }
        elsif ($notifiers->{webhook}) {
            if ($notifiers->{webhook}->notify($alert, $context)) {
                push @sent, 'webhook';
            }
        }
    }

    return \@sent;
}

1;

__END__

=head1 NAME

Purl::API::Controller::Alerts - Alert management endpoints

=head1 DESCRIPTION

Handles alert CRUD, checking, and notification sending.

=cut

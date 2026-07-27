package Purl::Alert::Scheduler;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

# ============================================
# Alert evaluation runner.
#
# Owns the "evaluate every alert rule, then fan the triggered ones out to
# their notification channels" logic. Deliberately knows NOTHING about HTTP:
# it is driven both by the server-side recurring timer (Server.pm, gated on
# cron leadership) and by POST /api/alerts/check (Controller::Alerts), so the
# two paths cannot drift apart.
#
# Before this module existed the logic lived only inside the controller, which
# meant alerts fired ONLY while a browser had the dashboard open — no open tab,
# no Telegram/Slack notification.
# ============================================

has 'storage' => (
    is       => 'ro',
    required => 1,
);

# Hashref of channel name => Purl::Alert::* notifier instance.
has 'notifiers' => (
    is      => 'ro',
    default => sub { {} },
);

# Evaluate all alert rules once. Returns:
#   { triggered => \@alerts, notifications => [ { alert => $name, sent => \@channels } ] }
# Never dies on a single channel failure — a broken webhook must not stop the
# remaining alerts from being delivered.
sub run_once {
    my ($self) = @_;

    my $triggered = $self->storage->check_alerts() // [];
    $triggered = [] unless ref $triggered eq 'ARRAY';

    my @notifications;
    for my $alert (@$triggered) {
        my $sent = $self->send_notifications($alert, { count => $alert->{count} });
        push @notifications, {
            alert => $alert->{name},
            sent  => $sent,
        } if @$sent;
    }

    return { triggered => $triggered, notifications => \@notifications };
}

# Deliver one triggered alert to the channel named by its notify_type.
# Returns an arrayref of the channel names that accepted the notification.
sub send_notifications {
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

Purl::Alert::Scheduler - Alert rule evaluation and notification fan-out

=head1 SYNOPSIS

    my $scheduler = Purl::Alert::Scheduler->new(
        storage   => $storage,
        notifiers => \%notifiers,
    );

    my $result = $scheduler->run_once();
    # { triggered => [...], notifications => [...] }

=head1 DESCRIPTION

Single home for alert evaluation. Two callers:

=over 4

=item * C<Purl::API::Server> — a C<Mojo::IOLoop-E<gt>recurring> timer gated on
cron leadership, so alerts fire server-side with no dashboard open. Interval
comes from C<alerts.check_interval_seconds> / C<PURL_ALERT_CHECK_INTERVAL>.

=item * C<Purl::API::Controller::Alerts::check> — the manual
C<POST /api/alerts/check> endpoint.

=back

=cut

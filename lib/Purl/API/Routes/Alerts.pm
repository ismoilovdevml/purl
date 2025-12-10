package Purl::API::Routes::Alerts;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_alert_routes);

# ============================================
# Alerts Routes Setup
# ============================================

sub setup_alert_routes {
    my ($protected, $storage, $notifiers, $send_notifications_func) = @_;

    # List alerts
    $protected->get('/alerts' => sub {
        my ($c) = @_;
        my $alerts = $storage->get_alerts();
        $c->render(json => { alerts => $alerts });
    });

    # Create alert
    $protected->post('/alerts' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name}) {
            $c->render(json => { error => 'Name required' }, status => 400);
            return;
        }

        $storage->create_alert(%$body);
        $c->render(json => { status => 'ok' });
    });

    # Update alert
    $protected->put('/alerts/:id' => sub {
        my ($c) = @_;
        my $id = $c->param('id');
        my $body = eval { decode_json($c->req->body) };

        $storage->update_alert($id, %$body);
        $c->render(json => { status => 'ok' });
    });

    # Delete alert
    $protected->delete('/alerts/:id' => sub {
        my ($c) = @_;
        my $id = $c->param('id');
        $storage->delete_alert($id);
        $c->render(json => { status => 'ok' });
    });

    # Check alerts
    $protected->post('/alerts/check' => sub {
        my ($c) = @_;
        my $triggered = $storage->check_alerts();

        # Send notifications for each triggered alert
        my @notifications;
        for my $alert (@$triggered) {
            my $sent = $send_notifications_func->($alert, { count => $alert->{count} });
            push @notifications, {
                alert  => $alert->{name},
                sent   => $sent,
            } if $sent && @$sent;
        }

        $c->render(json => {
            triggered     => $triggered,
            notifications => \@notifications,
        });
    });

    # Test notification endpoint
    $protected->post('/alerts/test-notification' => sub {
        my ($c) = @_;
        my $type = $c->param('type') // 'telegram';

        unless ($notifiers->{$type}) {
            return $c->render(
                json   => { error => "Notifier '$type' not configured" },
                status => 400
            );
        }

        my $result = $notifiers->{$type}->send_test();
        $c->render(json => {
            success => $result ? 1 : 0,
            type    => $type,
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Alerts - Alert management routes

=cut

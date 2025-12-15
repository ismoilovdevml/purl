package Purl::API::Routes::Alerts;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_alert_routes);

sub setup_alert_routes {
    my ($protected, $args) = @_;

    my $storage            = $args->{storage};
    my $notifiers          = $args->{notifiers};
    my $send_notifications = $args->{send_notifications};

    $protected->get('/alerts' => sub {
        my ($c) = @_;
        $c->render(json => { alerts => $storage->get_alerts() });
    });

    $protected->post('/alerts' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'Name required' }, status => 400) unless $body && $body->{name};
        $storage->create_alert(%$body);
        $c->render(json => { status => 'ok' });
    });

    $protected->put('/alerts/:id' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        $storage->update_alert($c->param('id'), %$body);
        $c->render(json => { status => 'ok' });
    });

    $protected->delete('/alerts/:id' => sub {
        my ($c) = @_;
        $storage->delete_alert($c->param('id'));
        $c->render(json => { status => 'ok' });
    });

    $protected->post('/alerts/check' => sub {
        my ($c) = @_;
        my $triggered = $storage->check_alerts();
        my @notifications;
        for my $alert (@$triggered) {
            my $sent = $send_notifications->($alert, { count => $alert->{count} });
            push @notifications, { alert => $alert->{name}, sent => $sent } if @$sent;
        }
        $c->render(json => { triggered => $triggered, notifications => \@notifications });
    });

    $protected->post('/alerts/test-notification' => sub {
        my ($c) = @_;
        my $type = $c->param('type') // 'telegram';
        return $c->render(json => { error => "Notifier '$type' not configured" }, status => 400) unless $notifiers->{$type};
        my $result = $notifiers->{$type}->send_test();
        $c->render(json => { success => $result ? 1 : 0, type => $type });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Alerts - Alert management routes

=cut

package Purl::Alert::Slack;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();

with 'Purl::Alert::Base';

has 'webhook_url' => (
    is       => 'ro',
    required => 1,
);

has 'channel' => (
    is      => 'ro',
    default => '',
);

has 'username' => (
    is      => 'ro',
    default => 'Purl Alert',
);

has 'icon_emoji' => (
    is      => 'ro',
    default => ':warning:',
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        HTTP::Tiny->new(
            timeout => 10,
            agent   => 'Purl-Alert/1.0',
        )
    },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8 },
);

sub deliver {
    my ($self, $message) = @_;

    my $payload = $self->_format_slack_message($message);

    my $response = $self->_http->post($self->webhook_url, {
        content => $self->_json->encode($payload),
        headers => { 'Content-Type' => 'application/json' },
    });

    unless ($response->{success}) {
        warn "Slack send failed: $response->{status} - $response->{content}";
        return 0;
    }

    return 1;
}

sub _format_slack_message {
    my ($self, $msg) = @_;

    my $color = $msg->{severity} eq 'critical' ? '#dc3545' : '#ffc107';
    my $icon = $msg->{severity} eq 'critical' ? ':rotating_light:' : ':warning:';

    my $payload = {
        username   => $self->username,
        icon_emoji => $self->icon_emoji,
        attachments => [
            {
                color  => $color,
                title  => "$icon $msg->{alert}",
                fields => [
                    {
                        title => 'Query',
                        value => "`$msg->{query}`",
                        short => 0,
                    },
                    {
                        title => 'Count',
                        value => "$msg->{count} / $msg->{threshold}",
                        short => 1,
                    },
                    {
                        title => 'Window',
                        value => "$msg->{window} min",
                        short => 1,
                    },
                    {
                        title => 'Severity',
                        value => uc($msg->{severity}),
                        short => 1,
                    },
                    {
                        title => 'Time',
                        value => $msg->{time},
                        short => 1,
                    },
                ],
                footer => 'Purl Log Aggregator',
                ts     => time(),
            }
        ],
    };

    $payload->{channel} = $self->channel if $self->channel;

    return $payload;
}

sub send_test {
    my ($self) = @_;

    return $self->deliver({
        title     => 'Test Alert',
        alert     => 'Test Connection',
        query     => 'level:ERROR',
        count     => 5,
        threshold => 10,
        window    => 5,
        time      => scalar localtime(),
        severity  => 'warning',
    });
}

1;

__END__

=head1 NAME

Purl::Alert::Slack - Slack webhook alert notifier

=head1 SYNOPSIS

    use Purl::Alert::Slack;

    my $slack = Purl::Alert::Slack->new(
        name        => 'my-slack',
        webhook_url => 'https://hooks.slack.com/services/T00/B00/XXX',
        channel     => '#alerts',  # optional
    );

    # Send test message
    $slack->send_test;

    # Send alert
    $slack->notify($alert, { count => 15 });

=head1 CONFIGURATION

1. Go to Slack App Directory
2. Create Incoming Webhook
3. Choose channel and get webhook URL

=cut

package Purl::Alert::Webhook;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

with 'Purl::Alert::Base';

has 'url' => (
    is       => 'ro',
    required => 1,
);

has 'method' => (
    is      => 'ro',
    default => 'POST',
);

has 'headers' => (
    is      => 'ro',
    default => sub { {} },
);

has 'auth_token' => (
    is      => 'ro',
    default => '',
);

# Note: _http and _json attributes inherited from Purl::Alert::Base

sub deliver {
    my ($self, $message) = @_;

    my %headers = (
        'Content-Type' => 'application/json',
        %{$self->headers},
    );

    if ($self->auth_token) {
        $headers{'Authorization'} = 'Bearer ' . $self->auth_token;
    }

    my $payload = $self->_json->encode({
        event     => 'purl.alert',
        timestamp => time(),
        alert     => $message,
    });

    my $response;
    if (uc($self->method) eq 'POST') {
        $response = $self->_http->post($self->url, {
            content => $payload,
            headers => \%headers,
        });
    } elsif (uc($self->method) eq 'PUT') {
        $response = $self->_http->put($self->url, {
            content => $payload,
            headers => \%headers,
        });
    } else {
        warn "Unsupported HTTP method: " . $self->method;
        return 0;
    }

    unless ($response->{success}) {
        warn "Webhook send failed: $response->{status} - $response->{content}";
        return 0;
    }

    return 1;
}

# Note: send_test method inherited from Purl::Alert::Base

1;

__END__

=head1 NAME

Purl::Alert::Webhook - Custom webhook alert notifier

=head1 SYNOPSIS

    use Purl::Alert::Webhook;

    my $webhook = Purl::Alert::Webhook->new(
        name       => 'my-webhook',
        url        => 'https://example.com/alerts',
        method     => 'POST',
        auth_token => 'secret-token',
        headers    => {
            'X-Custom-Header' => 'value',
        },
    );

    # Send test message
    $webhook->send_test;

    # Send alert
    $webhook->notify($alert, { count => 15 });

=head1 PAYLOAD FORMAT

    {
        "event": "purl.alert",
        "timestamp": 1702234567,
        "alert": {
            "title": "Alert Name",
            "query": "level:ERROR",
            "count": 15,
            "threshold": 10,
            "window": 5,
            "severity": "critical",
            "time": "Wed Dec 10 22:30:00 2025"
        }
    }

=cut

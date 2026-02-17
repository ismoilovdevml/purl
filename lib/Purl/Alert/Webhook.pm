package Purl::Alert::Webhook;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();
use Digest::SHA qw(hmac_sha256_hex);

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

has 'signing_secret' => (
    is        => 'ro',
    predicate => 'has_signing_secret',
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

    if ($self->has_signing_secret) {
        my $signature = hmac_sha256_hex($payload, $self->signing_secret);
        $headers{'X-Purl-Signature'} = "sha256=$signature";
    }

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

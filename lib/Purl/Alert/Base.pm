package Purl::Alert::Base;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use HTTP::Tiny;
use JSON::XS ();
use namespace::clean;

requires 'deliver';

has 'name' => (
    is       => 'ro',
    required => 1,
);

has 'enabled' => (
    is      => 'rw',
    default => 1,
);

has 'throttle_seconds' => (
    is      => 'ro',
    default => 60,
);

has '_last_sent' => (
    is      => 'rw',
    default => 0,
);

# Common HTTP client for all alert notifiers
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

# Common JSON encoder for all alert notifiers
has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8 },
);

sub can_send {
    my ($self) = @_;
    return 0 unless $self->enabled;
    return 1 if time() - $self->_last_sent >= $self->throttle_seconds;
    return 0;
}

sub notify {
    my ($self, $alert, $context) = @_;

    return 0 unless $self->can_send;

    my $message = $self->format_message($alert, $context);
    my $result = $self->deliver($message);

    if ($result) {
        $self->_last_sent(time());
    }

    return $result;
}

sub format_message {
    my ($self, $alert, $context) = @_;

    my $count = $context->{count} // 0;
    my $threshold = $alert->{threshold} // 0;
    my $window = $alert->{window_minutes} // 5;
    my $query = $alert->{query} // '';

    return {
        title     => "Alert: $alert->{name}",
        alert     => $alert->{name},
        query     => $query,
        count     => $count,
        threshold => $threshold,
        window    => $window,
        time      => scalar localtime(),
        severity  => $count >= $threshold * 2 ? 'critical' : 'warning',
    };
}

# Common test message sender
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

Purl::Alert::Base - Base role for alert notifiers

=head1 SYNOPSIS

    package Purl::Alert::MyNotifier;
    use Moo;
    with 'Purl::Alert::Base';

    sub send {
        my ($self, $message) = @_;
        # Send notification
        return 1;
    }

=cut

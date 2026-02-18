package Purl::Broadcast::Local;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json decode_json);

with 'Purl::Broadcast';

# Subscribers keyed by channel => { $id => $callback }
has '_subscribers' => (
    is      => 'ro',
    default => sub { {} },
);

# Auto-incrementing subscription ID
has '_next_id' => (
    is      => 'rw',
    default => sub { 0 },
);

sub publish {
    my ($self, $channel, $message) = @_;
    my $subs = $self->_subscribers->{$channel} // {};
    my $json = ref $message ? encode_json($message) : $message;

    for my $id (keys %$subs) {
        eval { $subs->{$id}->($json) };
        warn "Broadcast::Local publish error for subscriber $id: $@" if $@;
    }

    return scalar keys %$subs;
}

sub subscribe {
    my ($self, $channel, $callback) = @_;
    my $id = $self->_next_id + 1;
    $self->_next_id($id);

    $self->_subscribers->{$channel} //= {};
    $self->_subscribers->{$channel}{$id} = $callback;

    return $id;
}

sub unsubscribe {
    my ($self, $sub_id) = @_;
    for my $channel (keys %{$self->_subscribers}) {
        delete $self->_subscribers->{$channel}{$sub_id};
    }
    return 1;
}

sub is_connected {
    return 1;  # Local is always connected
}

sub subscriber_count {
    my ($self, $channel) = @_;
    return 0 unless $channel && $self->_subscribers->{$channel};
    return scalar keys %{$self->_subscribers->{$channel}};
}

1;

__END__

=head1 NAME

Purl::Broadcast::Local - In-memory broadcast for single-instance deployments

=head1 DESCRIPTION

Default broadcast backend that delivers messages to subscribers within the
same process. Used when Redis is not configured.

This is functionally equivalent to the original WebSocket array-based
broadcast in Logs.pm, but abstracted behind the Purl::Broadcast role.

=cut

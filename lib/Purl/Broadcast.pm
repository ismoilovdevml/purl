package Purl::Broadcast;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

requires 'publish';       # publish($channel, $message_hashref)
requires 'subscribe';     # subscribe($channel, $callback) -> subscription id
requires 'unsubscribe';   # unsubscribe($subscription_id)
requires 'is_connected';  # is_connected() -> bool

has 'default_channel' => (
    is      => 'ro',
    default => sub { 'purl:logs:broadcast' },
);

1;

__END__

=head1 NAME

Purl::Broadcast - Role interface for cross-instance log broadcasting

=head1 SYNOPSIS

    package Purl::Broadcast::Local;
    use Moo;
    with 'Purl::Broadcast';

    sub publish { ... }
    sub subscribe { ... }
    sub unsubscribe { ... }
    sub is_connected { ... }

=head1 DESCRIPTION

Defines the interface for broadcast backends used to deliver live-tail
WebSocket messages across multiple Purl replicas. Implementations:

    Purl::Broadcast::Local  - In-memory (single instance, default)
    Purl::Broadcast::Redis  - Redis Pub/Sub (multi-replica)

=cut

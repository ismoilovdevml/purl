package Purl::Broadcast::Redis;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json decode_json);
use Time::HiRes ();

with 'Purl::Broadcast';

# Redis connection URL (e.g., redis://redis:6379)
has 'redis_url' => (
    is       => 'ro',
    required => 1,
);

# Mojo::Redis instance (lazy; built and PING-verified on first use). undef when
# Redis is unreachable or Mojo::Redis is not installed.
has '_redis' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_redis',
);

# Upper bound (seconds, fractional allowed) for the startup PING, so an
# unreachable or blackholed Redis fails fast instead of Mojo::Redis's 10s
# connect timeout (or forever, if a peer accepts TCP but never answers).
has 'connect_timeout' => (
    is      => 'ro',
    default => sub { 2 },
);

# Local fallback for when Redis is unavailable
has '_local_fallback' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        require Purl::Broadcast::Local;
        return Purl::Broadcast::Local->new();
    },
);

# Track whether Redis is available
has '_redis_available' => (
    is      => 'rw',
    default => sub { 0 },
);

# Local subscriber registry: channel => { $id => $callback }
has '_subscribers' => (
    is      => 'ro',
    default => sub { {} },
);

# Auto-incrementing subscription ID
has '_next_id' => (
    is      => 'rw',
    default => sub { 0 },
);

# PubSub listener handles (for cleanup)
has '_pubsub_handles' => (
    is      => 'ro',
    default => sub { {} },
);

sub _build_redis {
    my ($self) = @_;

    my $redis;
    my $ok = eval {
        require Mojo::Redis;
        $self->_ping_once;
        $redis = Mojo::Redis->new($self->redis_url);
        1;
    };
    if (!$ok) {
        my $err = $@ || 'unknown error';
        warn "Broadcast::Redis: Redis unavailable at @{[ $self->redis_url ]}: $err";
        $self->_redis_available(0);
        return undef;
    }

    $self->_redis_available(1);
    return $redis;
}

# Real round-trip on a throwaway client, bounded by connect_timeout. A separate
# client keeps the long-lived one free of the blocking connection, and it is
# closed here, before Server.pm's prefork workers are forked.
sub _ping_once {
    my ($self) = @_;
    my $probe = Mojo::Redis->new($self->redis_url);
    local $SIG{ALRM} = sub { die "PING timed out after @{[ $self->connect_timeout ]}s\n" };
    Time::HiRes::alarm($self->connect_timeout);
    my $ok = eval { $probe->db->ping; 1 };
    my $err = $@;
    Time::HiRes::alarm(0);
    die $err unless $ok;
    return 1;
}

# True when Redis is built, PING-verified, and has not failed at runtime.
# Touching _redis runs the lazy builder, so the first call does the PING.
sub _use_redis {
    my ($self) = @_;
    return defined $self->_redis && $self->_redis_available ? 1 : 0;
}

sub publish {
    my ($self, $channel, $message) = @_;
    my $json = ref $message ? encode_json($message) : $message;

    # When Redis is connected, publish to Redis only.
    # The Redis PubSub listener handles local delivery on ALL instances
    # (including this one), avoiding double delivery.
    if ($self->_use_redis) {
        eval {
            $self->_redis->pubsub->notify($channel => $json);
        };
        if ($@) {
            warn "Broadcast::Redis publish failed, falling back to local: $@";
            $self->_redis_available(0);
            # Redis failed — fall through to local delivery below
        } else {
            return 1;  # Redis handled it; listener will deliver locally
        }
    }

    # Fallback: deliver locally when Redis is unavailable
    return $self->_deliver_local($channel, $json);
}

sub subscribe {
    my ($self, $channel, $callback) = @_;
    my $id = $self->_next_id + 1;
    $self->_next_id($id);

    # Register local callback
    $self->_subscribers->{$channel} //= {};
    $self->_subscribers->{$channel}{$id} = $callback;

    # Set up Redis PubSub listener for this channel (once per channel)
    if ($self->_use_redis
        && !$self->_pubsub_handles->{$channel}) {
        eval {
            my $ps = $self->_redis->pubsub;
            $ps->listen($channel => sub {
                my ($ps_obj, $msg) = @_;
                # Deliver to all local subscribers on this instance
                $self->_deliver_local($channel, $msg);
            });
            $self->_pubsub_handles->{$channel} = 1;
        };
        if ($@) {
            warn "Broadcast::Redis subscribe to Redis failed: $@";
            $self->_redis_available(0);
        }
    }

    return $id;
}

sub unsubscribe {
    my ($self, $sub_id) = @_;
    for my $channel (keys %{$self->_subscribers}) {
        delete $self->_subscribers->{$channel}{$sub_id};

        # If no more local subscribers for this channel, unlisten from Redis
        if (!keys %{$self->_subscribers->{$channel}}) {
            delete $self->_subscribers->{$channel};
            if ($self->_use_redis
                && $self->_pubsub_handles->{$channel}) {
                eval {
                    $self->_redis->pubsub->unlisten($channel);
                };
                delete $self->_pubsub_handles->{$channel};
            }
        }
    }
    return 1;
}

sub is_connected {
    my ($self) = @_;
    return $self->_use_redis;
}

# Deliver message to local subscribers only (called from both publish and Redis listener)
sub _deliver_local {
    my ($self, $channel, $json) = @_;
    my $subs = $self->_subscribers->{$channel} // {};

    for my $id (keys %$subs) {
        eval { $subs->{$id}->($json) };
        warn "Broadcast::Redis local delivery error for subscriber $id: $@" if $@;
    }

    return scalar keys %$subs;
}

sub subscriber_count {
    my ($self, $channel) = @_;
    return 0 unless $channel && $self->_subscribers->{$channel};
    return scalar keys %{$self->_subscribers->{$channel}};
}

1;

__END__

=head1 NAME

Purl::Broadcast::Redis - Redis Pub/Sub broadcast for multi-replica deployments

=head1 DESCRIPTION

Uses Redis Pub/Sub to broadcast log messages across multiple Purl instances,
enabling live-tail WebSocket to work in multi-replica Kubernetes deployments.

The first use (normally C<is_connected> at server startup) builds the client
and sends a real C<PING>, bounded by C<connect_timeout> (default 2s).
C<is_connected> is true only if that PING succeeded and no later publish or
subscribe has failed. When Redis is unavailable (Mojo::Redis not installed,
unreachable, timed out, or failing at runtime), it falls back to local-only
delivery.

=head1 CONFIGURATION

Set C<PURL_REDIS_URL> environment variable:

    PURL_REDIS_URL=redis://redis:6379

=head1 MESSAGE FLOW

    Ingest API -> publish(channel, logs)
                      |
                      v
               Redis PUBLISH -----> Other Purl instances
                      |                    |
                      v                    v
               Local delivery        Local delivery
                      |                    |
                      v                    v
               WebSocket clients    WebSocket clients

=cut

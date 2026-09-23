package Purl::API::Routes::LiveTail;
use strict;
use warnings;
use 5.024;

use Mojo::JSON qw(decode_json);
use Purl::API::LiveTail qw(send_connected send_logs handle_client_message);

# ============================================
# WebSocket for live tail
#
# MUST hang off $protected, not $api: this is the live log firehose. On
# $api the handshake skipped check_auth entirely, so an anonymous client
# got 101 Switching Protocols and every ingested log while GET /api/logs
# correctly returned 401.
#
# Browsers cannot set custom headers on a WebSocket handshake, so the
# dashboard authenticates with the ambient session cookie — which the
# handshake DOES send (same origin) and which $protected's check_auth
# accepts. Programmatic clients still work via the X-API-Key header.
# The handshake is a GET, so the CSRF gate in $protected is a no-op.
# ============================================
sub register {
    my (%deps) = @_;
    my $protected   = $deps{protected};
    my $websockets  = $deps{websockets};
    my $broadcaster = $deps{broadcaster};

    $protected->websocket('/logs/stream' => sub {
        my ($c) = @_;
        my $ws = $c->tx;
        push @$websockets, $ws;
        my $bc = $broadcaster->();

        # Subscribe to broadcast channel for cross-replica delivery
        my $sub_id;
        if ($bc) {
            $sub_id = $bc->subscribe(
                $bc->default_channel,
                sub {
                    my ($json_msg) = @_;
                    eval {
                        my $logs = ref $json_msg ? $json_msg : decode_json($json_msg);
                        $logs = [$logs] unless ref $logs eq 'ARRAY';
                        # One typed {"type":"log","data":{...}} frame per log —
                        # see Purl::API::LiveTail for why the shape matters.
                        send_logs($ws, $logs);
                        1;
                    };
                },
            );
        }

        $c->on(message => sub { my (undef, $msg) = @_; handle_client_message($ws, $msg) });

        $c->on(finish => sub {
            # Unsubscribe from broadcast channel
            if ($bc && defined $sub_id) {
                $bc->unsubscribe($sub_id);
            }
            # Remove from local websockets array
            for my $i (0 .. $#$websockets) {
                if ($websockets->[$i] == $ws) {
                    splice @$websockets, $i, 1;
                    last;
                }
            }
        });

        my $mode = 'direct';
        if ($bc) {
            $mode = ref($bc) =~ /Redis/  ? 'redis'
                  : ref($bc) =~ /Prefork/ ? 'prefork'
                  :                         'local';
        }
        send_connected($ws, $mode);
    });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Routes::LiveTail - the authenticated live-tail WebSocket
(/api/logs/stream)

=cut

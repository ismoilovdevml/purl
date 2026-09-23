package Purl::API::Routes::LiveTail;
use strict;
use warnings;
use 5.024;

use Mojo::IOLoop;
use Mojo::JSON qw(decode_json);
use Purl::API::LiveTail qw(send_connected send_logs handle_client_message);
use Purl::Util::Principal qw(principal principal_via);

# How often an open socket re-checks the session that opened it. check_auth
# runs once, at the handshake; without this a socket opened before a logout,
# password change or user deletion kept streaming every log indefinitely.
# A package variable so tests can shorten it.
our $SESSION_RECHECK_SECONDS = 30;

# Close code for "your session is no longer valid" (4000-4999 is the
# application range; 4401 mirrors HTTP 401 so the client can tell it apart
# from a network drop and send the user to the login page).
my $WS_SESSION_REVOKED = 4401;

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
    my $auth        = $deps{auth_middleware};

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

        my $recheck = _watch_session($c, $ws, $auth);

        $c->on(finish => sub {
            Mojo::IOLoop->remove($recheck) if $recheck;
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

# A socket opened by a session cookie or a Basic credential is re-checked on
# a timer: the session must still be valid, the Basic user must still exist
# with the password that was verified at the handshake. An API-key socket is
# not: its key is not revocable per connection here.
# Returns the IOLoop timer id, or undef.
sub _watch_session {
    my ($c, $ws, $auth) = @_;
    return unless $auth;

    my $still_valid;
    my $via = principal_via($c);
    if ($via eq 'session') {
        my %session = %{ $c->session };    # what the handshake was accepted on
        $still_valid = sub { $_[0]->session_still_valid(\%session) };
    } elsif ($via eq 'basic') {
        my ($user, $hash) = @{ principal($c) }{qw(username password_hash)};
        $still_valid = sub { $_[0]->basic_still_valid($user, $hash) };
    } else {
        return;
    }

    return Mojo::IOLoop->recurring($SESSION_RECHECK_SECONDS => sub {
        my $mw = $auth->();
        return if $mw && $still_valid->($mw);
        $ws->finish($WS_SESSION_REVOKED, 'Session revoked');
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::LiveTail - the authenticated live-tail WebSocket
(/api/logs/stream)

=cut

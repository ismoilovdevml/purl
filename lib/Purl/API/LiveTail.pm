package Purl::API::LiveTail;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(from_json);

our @EXPORT_OK = qw(
    filter_logs
    send_connected
    send_logs
    handle_client_message
);

# ============================================================================
# Purl::API::LiveTail - the /api/logs/stream wire protocol, in one place.
#
# EVERY frame is a JSON object with a `type`. The dashboard
# (web/src/stores/logs.js) dispatches on it and silently drops anything else,
# so a bare array - which is what the server used to send - is invisible (#64).
#
#   server -> client
#     {"type":"connected","message":"...","broadcast_mode":"prefork"}
#     {"type":"pong"}
#     {"type":"log","data":{ ...one log object... }}     one frame per log
#
#   client -> server
#     {"type":"ping"}
#     {"type":"subscribe","filter":{level|service|host|query}}
#
# It lives here rather than inline in Server.pm's route closure because two
# call sites produce log frames - the broadcast subscription in Server.pm and
# the no-broadcaster fallback in Controller::Logs - and they drifting apart is
# precisely how one of them ended up shipping the wrong shape.
# ============================================================================

# Match a batch of logs against one subscriber's filter. Returns the matching
# logs. An empty filter matches everything (the default for a fresh socket:
# the client only sends `subscribe` when the user narrows the stream).
sub filter_logs {
    my ($filter, $logs) = @_;
    $filter //= {};

    my @matches;

    for my $log (@$logs) {
        # Level filter (exact match or array)
        if ($filter->{level}) {
            if (ref $filter->{level} eq 'ARRAY') {
                my %allowed = map { uc($_) => 1 } @{ $filter->{level} };
                next unless $allowed{ uc($log->{level} // '') };
            } else {
                next if uc($log->{level} // '') ne uc($filter->{level});
            }
        }

        # Service filter (exact match or wildcard)
        if ($filter->{service}) {
            my $service = $log->{service} // '';
            my $pattern = $filter->{service};
            if ($pattern =~ /\*/) {
                # Convert wildcard to regex
                $pattern =~ s/\./\\./g;
                $pattern =~ s/\*/.*/g;
                next unless $service =~ /^$pattern$/i;
            } else {
                next if lc($service) ne lc($pattern);
            }
        }

        # Host filter
        if ($filter->{host}) {
            next if lc($log->{host} // '') ne lc($filter->{host});
        }

        # Message contains filter (case-insensitive)
        if ($filter->{query}) {
            my $message = $log->{message} // '';
            next unless index(lc($message), lc($filter->{query})) >= 0;
        }

        push @matches, $log;
    }

    return @matches;
}

# Opening greeting. `broadcast_mode` is diagnostic: it tells an operator
# whether this socket can see logs ingested by other workers/replicas.
sub send_connected {
    my ($ws, $mode) = @_;
    return 0 unless $ws;

    $ws->send({ json => {
        type           => 'connected',
        message        => 'Connected to log stream',
        broadcast_mode => $mode // 'direct',
    } });

    return 1;
}

# Send the logs this socket's filter accepts, ONE typed frame per log.
#
# Not one frame per batch: the client prepends `data.data` as a single row, so
# a batch of 50 would arrive as a single unusable entry.
sub send_logs {
    my ($ws, $logs) = @_;
    return 0 unless $ws && ref $logs eq 'ARRAY' && @$logs;

    my $sent = 0;
    for my $log (filter_logs($ws->{filter}, $logs)) {
        $ws->send({ json => { type => 'log', data => $log } });
        $sent++;
    }

    return $sent;
}

# Handle one client frame. Returns the type it acted on ('' when the frame is
# unusable), which is what the tests assert against.
#
# from_json, NOT decode_json: a WebSocket text frame is already a decoded
# CHARACTER string. decode_json wants UTF-8 bytes and dies on any non-ASCII,
# which would drop a `subscribe` whose query filter contains one.
sub handle_client_message {
    my ($ws, $raw) = @_;
    return '' unless $ws && defined $raw;

    my $data = eval { from_json($raw) };
    return '' unless ref $data eq 'HASH';

    my $type = $data->{type} // '';

    if ($type eq 'ping') {
        # Mandatory, not decorative: logs.js leaves `pongSupported` false
        # until it sees one, and with it false the heartbeat never times out
        # a half-open socket.
        $ws->send({ json => { type => 'pong' } });
        return 'ping';
    }

    if ($type eq 'subscribe') {
        $ws->{filter} = ref $data->{filter} eq 'HASH' ? $data->{filter} : {};
        return 'subscribe';
    }

    return $type;
}

1;

__END__

=head1 NAME

Purl::API::LiveTail - Wire protocol for the /api/logs/stream WebSocket

=head1 SYNOPSIS

    use Purl::API::LiveTail qw(send_connected send_logs handle_client_message);

    send_connected($ws, 'prefork');
    $c->on(message => sub { handle_client_message($ws, $_[1]) });
    send_logs($ws, \@logs);

=head1 DESCRIPTION

Every frame on the live-tail socket is a JSON object carrying a C<type>. This
module is the only place that shape is defined, so the broadcast path and the
direct-delivery fallback cannot disagree about it.

Per-connection filter state is kept on the transaction itself
(C<< $ws->{filter} >>), set by the client's C<subscribe> frame.

=cut

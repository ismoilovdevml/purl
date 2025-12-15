package Purl::API::Routes::WebSocket;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(encode_json decode_json);
use Mojolicious::Lite -signatures;

our @EXPORT_OK = qw(setup_websocket_routes);

sub setup_websocket_routes {
    my ($api, $args) = @_;

    my $websockets = $args->{websockets};

    $api->websocket('/logs/stream' => sub ($c) {
        my $ws = $c->tx;
        my $origin = $c->req->headers->header('Origin') // '';
        my $host = $c->req->headers->host // '';

        if ($origin && $host) {
            my ($origin_host) = $origin =~ m{^https?://([^/]+)};
            unless ($origin_host && $origin_host eq $host) {
                app->log->warn("WebSocket origin mismatch: origin=$origin, host=$host");
                $c->send(encode_json({ type => 'error', error => 'Origin not allowed' }));
                $ws->finish(4003 => 'Origin not allowed');
                return;
            }
        }

        push @$websockets, $ws;

        $c->on(message => sub ($c, $msg) {
            my $data = eval { decode_json($msg) };
            $ws->{filter} = $data->{filter} // {} if $data && $data->{type} eq 'subscribe';
        });

        $c->on(finish => sub ($c, $code, $reason) {
            @$websockets = grep { $_ != $ws } @$websockets;
        });

        $c->send(encode_json({ type => 'connected', message => 'Connected to log stream' }));
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::WebSocket - WebSocket live tail routes

=cut

package Purl::API::Routes::Config;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_config_routes);

sub setup_config_routes {
    my ($protected, $args) = @_;

    my $config  = $args->{config};
    my $storage = $args->{storage};

    $protected->get('/config' => sub {
        my ($c) = @_;
        my $storage_config = $config->{storage} // {};
        my $ch_config = $storage_config->{clickhouse} // {};
        $c->render(json => {
            server => { host => $ENV{PURL_HOST} // '0.0.0.0', port => $ENV{PURL_PORT} // 3000 },
            clickhouse => {
                host => $ENV{PURL_CLICKHOUSE_HOST} // $ch_config->{host} // 'localhost',
                port => $ENV{PURL_CLICKHOUSE_PORT} // $ch_config->{port} // 8123,
                database => $ENV{PURL_CLICKHOUSE_DATABASE} // $ch_config->{database} // 'purl',
                user => $ENV{PURL_CLICKHOUSE_USER} // $ch_config->{username} // 'default',
                password_set => ($ENV{PURL_CLICKHOUSE_PASSWORD} || $ch_config->{password}) ? 1 : 0,
            },
            retention => { days => $ENV{PURL_RETENTION_DAYS} // $storage_config->{retention_days} // 30 },
            auth => { enabled => $ENV{PURL_AUTH_ENABLED} // 0, keys_set => $ENV{PURL_API_KEYS} ? 1 : 0 },
        });
    });

    $protected->get('/config/retention' => sub {
        my ($c) = @_;
        my $days = $ENV{PURL_RETENTION_DAYS} // $config->{storage}{retention_days} // 30;
        my $stats = eval { $storage->stats() } // {};
        $c->render(json => {
            retention_days => int($days),
            oldest_log => $stats->{oldest_log}, newest_log => $stats->{newest_log},
            total_logs => $stats->{total_logs} // 0, db_size_mb => $stats->{db_size_mb} // 0,
        });
    });

    $protected->put('/config/retention' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'days required' }, status => 400) unless $body && $body->{days};
        my $days = int($body->{days});
        return $c->render(json => { error => 'days must be between 1 and 365' }, status => 400) if $days < 1 || $days > 365;
        eval { $storage->update_retention($days) };
        return $c->render(json => { error => "Failed: $@" }, status => 500) if $@;
        $c->render(json => { status => 'ok', retention_days => $days, message => "Retention updated to $days days." });
    });

    $protected->post('/config/test-clickhouse' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) } // {};
        my $host = $body->{host} // $ENV{PURL_CLICKHOUSE_HOST} // 'localhost';
        my $port = $body->{port} // $ENV{PURL_CLICKHOUSE_PORT} // 8123;
        my $user = $body->{user} // $ENV{PURL_CLICKHOUSE_USER} // 'default';
        my $password = $body->{password} // $ENV{PURL_CLICKHOUSE_PASSWORD} // '';

        eval {
            require HTTP::Tiny;
            require URI::Escape;
            my $http = HTTP::Tiny->new(timeout => 5);
            my $url = "http://$host:$port/?query=" . URI::Escape::uri_escape("SELECT 1");
            my %headers;
            if ($user && $password) {
                require MIME::Base64;
                $headers{'Authorization'} = 'Basic ' . MIME::Base64::encode_base64("$user:$password", '');
            }
            my $response = $http->get($url, { headers => \%headers });
            if ($response->{success}) {
                $c->render(json => { success => 1, message => "Connected to ClickHouse at $host:$port" });
            } else {
                $c->render(json => { success => 0, error => "Connection failed: $response->{status}" }, status => 400);
            }
        };
        $c->render(json => { success => 0, error => "Error: $@" }, status => 500) if $@;
    });

    $protected->get('/sources' => sub {
        my ($c) = @_;
        $c->render(json => { sources => $config->{sources} // [] });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Config - Server configuration routes

=cut

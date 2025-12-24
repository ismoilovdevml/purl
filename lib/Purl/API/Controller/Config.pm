package Purl::API::Controller::Config;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);
use HTTP::Tiny;
use MIME::Base64 qw(encode_base64);
use URI::Escape qw(uri_escape);

extends 'Purl::API::Controller::Base';

# Reference to main config hash
has 'main_config' => (
    is      => 'ro',
    default => sub { {} },
);

sub get_config {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $storage_config = $self->main_config->{storage} // {};
        my $ch_config = $storage_config->{clickhouse} // {};

        $c->render(json => {
            server => {
                host => $ENV{PURL_HOST} // '0.0.0.0',
                port => $ENV{PURL_PORT} // 3000,
            },
            clickhouse => {
                host     => $ENV{PURL_CLICKHOUSE_HOST} // $ch_config->{host} // 'localhost',
                port     => $ENV{PURL_CLICKHOUSE_PORT} // $ch_config->{port} // 8123,
                database => $ENV{PURL_CLICKHOUSE_DATABASE} // $ch_config->{database} // 'purl',
                user     => $ENV{PURL_CLICKHOUSE_USER} // $ch_config->{username} // 'default',
                password_set => ($ENV{PURL_CLICKHOUSE_PASSWORD} || $ch_config->{password}) ? 1 : 0,
            },
            retention => {
                days => $ENV{PURL_RETENTION_DAYS} // $storage_config->{retention_days} // 30,
            },
            auth => {
                enabled  => $ENV{PURL_AUTH_ENABLED} // 0,
                keys_set => $ENV{PURL_API_KEYS} ? 1 : 0,
            },
        });
    });
}

sub get_retention {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $days = $ENV{PURL_RETENTION_DAYS} // $self->main_config->{storage}{retention_days} // 30;
        my $stats = eval { $self->storage->stats() } // {};

        $c->render(json => {
            retention_days => int($days),
            oldest_log     => $stats->{oldest_log},
            newest_log     => $stats->{newest_log},
            total_logs     => $stats->{total_logs} // 0,
            db_size_mb     => $stats->{db_size_mb} // 0,
        });
    });
}

sub update_retention {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $self->render_error($c, 'days required', 400);
            return;
        }

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $self->render_error($c, 'days must be between 1 and 365', 400);
            return;
        }

        my $result = eval { $self->storage->update_retention($days) };
        if ($@) {
            $self->render_error($c, "Failed to update retention: $@", 500);
            return;
        }

        $c->render(json => {
            status         => 'ok',
            retention_days => $days,
            message        => "Retention updated to $days days. Note: Set PURL_RETENTION_DAYS=$days in .env for persistence.",
        });
    });
}

sub test_clickhouse {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };

        my $host     = $body->{host} // $ENV{PURL_CLICKHOUSE_HOST} // 'localhost';
        my $port     = $body->{port} // $ENV{PURL_CLICKHOUSE_PORT} // 8123;
        my $database = $body->{database} // $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl';
        my $user     = $body->{user} // $ENV{PURL_CLICKHOUSE_USER} // 'default';
        my $password = $body->{password} // $ENV{PURL_CLICKHOUSE_PASSWORD} // '';

        eval {
            my $http = HTTP::Tiny->new(timeout => 5);
            my $url = "http://$host:$port/?query=" . uri_escape("SELECT 1");

            my %headers;
            if ($user && $password) {
                $headers{'Authorization'} = 'Basic ' . encode_base64("$user:$password", '');
            }

            my $response = $http->get($url, { headers => \%headers });

            if ($response->{success}) {
                $c->render(json => {
                    success => 1,
                    message => "Successfully connected to ClickHouse at $host:$port",
                    version => $response->{headers}{'x-clickhouse-server-display-name'} // 'unknown',
                });
            } else {
                $c->render(json => {
                    success => 0,
                    error   => "Connection failed: $response->{status} $response->{reason}",
                }, status => 400);
            }
        };
        if ($@) {
            $c->render(json => {
                success => 0,
                error   => "Connection error: $@",
            }, status => 500);
        }
    });
}

sub get_sources {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $sources = $self->main_config->{sources} // [];
        $c->render(json => { sources => $sources });
    });
}

sub clear_cache {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # Clear the shared cache reference
        my $cache = $self->cache;
        %$cache = ();
        $c->render(json => { status => 'ok', message => 'Cache cleared' });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Config - Server configuration endpoints

=head1 DESCRIPTION

Handles read-only configuration display and connection testing.

=cut

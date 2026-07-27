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
use Socket qw(getaddrinfo getnameinfo AF_INET AF_INET6 SOCK_STREAM NI_NUMERICHOST NIx_NOSERV);

use Purl::Util::ClientIP qw(ip_in_list);

extends 'Purl::API::Controller::Base';

# Reference to main config hash
has 'main_config' => (
    is      => 'ro',
    default => sub { {} },
);

# ============================================
# SSRF guard for POST /api/config/test-clickhouse
#
# That endpoint takes host+port from the request body, performs an outbound
# HTTP GET and hands the caller the status/reason — a textbook SSRF probe.
# Unrestricted it turns any authenticated account into an internal port
# scanner and a reader of cloud instance-metadata services.
#
# Blocked destinations (post-DNS-resolution, so a hostname resolving into
# these ranges is caught too):
#   loopback, RFC1918 private, link-local (incl. 169.254.169.254 metadata),
#   CGNAT, "this network", multicast/reserved, and the IPv6 equivalents.
# ============================================
my @BLOCKED_RANGES = (
    '0.0.0.0/8',            # "this network"
    '10.0.0.0/8',           # RFC1918
    '127.0.0.0/8',          # loopback
    '169.254.0.0/16',       # link-local — AWS/GCP/Azure metadata (169.254.169.254)
    '172.16.0.0/12',        # RFC1918
    '192.0.0.0/24',         # IETF protocol assignments
    '192.168.0.0/16',       # RFC1918
    '100.64.0.0/10',        # CGNAT
    '224.0.0.0/4',          # multicast
    '240.0.0.0/4',          # reserved
    '::1/128',              # IPv6 loopback
    '::/128',               # IPv6 unspecified
    'fc00::/7',             # IPv6 unique-local
    'fe80::/10',            # IPv6 link-local
);

# Resolve $host and return ($reason, $ip): a reason string when it must not be
# contacted, or (undef, $ip) with the address that was actually validated.
#
# The caller MUST connect to the returned $ip rather than re-using $host.
# Resolving here and letting HTTP::Tiny resolve again is a TOCTOU window: an
# attacker-controlled name with a short TTL can answer with a public address
# for this check and 169.254.169.254 for the connection. Pinning the validated
# address closes that.
#
# Reuses Purl::Util::ClientIP::ip_in_list for the CIDR matching rather than
# re-implementing prefix maths.
sub _resolve_safe_host {
    my ($host) = @_;

    return 'host is required' unless defined $host && length $host;
    # Reject anything that is not a bare hostname/IP: no scheme, credentials,
    # path or embedded port can smuggle a different target past the check.
    return 'host contains illegal characters'
        if $host =~ m{[/\@\\\s?#]}
        || ($host =~ /:/ && $host !~ /^[0-9a-fA-F:]+$/);

    my ($err, @addrs) = getaddrinfo($host, '', { socktype => SOCK_STREAM });
    return "host does not resolve: $err" if $err;
    return 'host does not resolve' unless @addrs;

    my $first_ip;
    for my $ai (@addrs) {
        next unless $ai->{family} == AF_INET || $ai->{family} == AF_INET6;
        my ($nerr, $ip) = getnameinfo($ai->{addr}, NI_NUMERICHOST, NIx_NOSERV);
        next if $nerr;
        $ip =~ s/%.*$//;   # strip IPv6 zone id
        return "host resolves to a blocked address ($ip)"
            if ip_in_list($ip, \@BLOCKED_RANGES);
        $first_ip //= $ip;
    }

    return 'host does not resolve to a usable address' unless defined $first_ip;

    return (undef, $first_ip);
}

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
        # Retention drives the ClickHouse TTL: dropping it to 1 day destroys
        # log history. Admin only.
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless (ref $body eq 'HASH' && $body->{days}) {
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
        # This endpoint makes an outbound request to a caller-chosen address
        # and reports the result — admin only, never a viewer.
        return unless $self->require_role($c, 'admin');

        # An empty body is legitimate ("test my CURRENT connection"); a body
        # that is present but not decodable JSON is a client bug, and letting
        # it through would autovivify $body->{host} on undef.
        my $raw = $c->req->body // '';
        my $body = {};
        if (length $raw) {
            $body = eval { decode_json($raw) };
            unless (ref $body eq 'HASH') {
                $self->render_error($c, 'Invalid JSON payload', 400);
                return;
            }
        }

        my $configured_host = $ENV{PURL_CLICKHOUSE_HOST}
            // ($self->main_config->{storage}{clickhouse}{host}) // 'localhost';

        my $host     = $body->{host} // $configured_host;
        my $port     = $body->{port} // $ENV{PURL_CLICKHOUSE_PORT} // 8123;
        my $database = $body->{database} // $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl';
        my $user     = $body->{user} // $ENV{PURL_CLICKHOUSE_USER} // 'default';
        my $password = $body->{password} // $ENV{PURL_CLICKHOUSE_PASSWORD} // '';

        unless ($port =~ /^\d+$/ && $port > 0 && $port <= 65535) {
            $self->render_error($c, 'Invalid port', 400);
            return;
        }

        # SSRF gate. Skipped when the target IS the server's own configured
        # ClickHouse endpoint (already trusted, and usually private), and
        # opt-out-able for self-hosted operators whose ClickHouse genuinely
        # lives on a private LAN address they want to test before switching.
        #
        # The exemption pins the PORT too. Matching on host alone let
        # {"host":"localhost","port":22} skip the gate entirely and report
        # whether the connection succeeded — a loopback/pod port scanner, which
        # is exactly what 127.0.0.0/8 is in @BLOCKED_RANGES to prevent.
        my $configured_port = $ENV{PURL_CLICKHOUSE_PORT}
            // ($self->main_config->{storage}{clickhouse}{port}) // 8123;

        my $trusted_target = ($host eq $configured_host && $port eq $configured_port)
            || ($ENV{PURL_ALLOW_PRIVATE_DB_TEST} // '') eq '1';

        my $connect_host = $host;
        unless ($trusted_target) {
            my ($reason, $ip) = _resolve_safe_host($host);
            if ($reason) {
                $self->render_error($c, "Refusing to connect: $reason", 400);
                return;
            }
            $connect_host = $ip;
        }

        eval {
            my $http = HTTP::Tiny->new(timeout => 5);
            # Bracket IPv6 literals; $connect_host is the address we validated.
            my $target = $connect_host =~ /:/ ? "[$connect_host]" : $connect_host;
            my $url = "http://$target:$port/?query=" . uri_escape("SELECT 1");

            my %headers;
            if ($user && $password) {
                $headers{'Authorization'} = 'Basic ' . encode_base64("$user:$password", '');
            }
            # Connecting by IP, so carry the original name for vhost routing.
            $headers{'Host'} = ($host =~ /:/ ? "[$host]" : $host) . ":$port"
                if $connect_host ne $host;

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
        return unless $self->require_role($c, 'admin');

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

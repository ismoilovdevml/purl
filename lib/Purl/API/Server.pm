package Purl::API::Server;
use strict;
use warnings;
use 5.024;

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Digest::MD5 qw(md5_hex);
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);

use Purl::Storage::ClickHouse;

# Package-level state
my $storage;
my $config = {};
my $websockets = [];

# Metrics counters
my %metrics = (
    requests_total     => 0,
    requests_by_path   => {},
    errors_total       => 0,
    logs_ingested      => 0,
    query_duration_sum => 0,
    query_count        => 0,
    start_time         => time(),
);

# Simple in-memory cache
my %cache;
my $cache_ttl = 60;  # seconds

# Rate limiting state
my %rate_limit;
my $rate_limit_window = 60;  # seconds
my $rate_limit_max = 1000;   # requests per window

sub new {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    $cache_ttl = $config->{cache}{ttl} // 60;
    $rate_limit_max = $config->{rate_limit}{max_requests} // 1000;
    return bless {}, $class;
}

sub _build_storage {
    my $storage_config = $config->{storage} // {};
    my $retention_days = $storage_config->{retention_days} // 30;
    my $ch_config = $storage_config->{clickhouse} // {};
    return Purl::Storage::ClickHouse->new(
        host           => $ENV{PURL_CLICKHOUSE_HOST} // $ch_config->{host} // 'localhost',
        port           => $ENV{PURL_CLICKHOUSE_PORT} // $ch_config->{port} // 8123,
        database       => $ENV{PURL_CLICKHOUSE_DATABASE} // $ch_config->{database} // 'purl',
        username       => $ENV{PURL_CLICKHOUSE_USER} // $ch_config->{username} // 'default',
        password       => $ENV{PURL_CLICKHOUSE_PASSWORD} // $ch_config->{password} // '',
        buffer_size    => $ch_config->{buffer_size} // 1000,
        retention_days => $retention_days,
    );
}

# Cache helpers
sub _cache_get {
    my ($key) = @_;
    my $entry = $cache{$key};
    return unless $entry;
    return if $entry->{expires} < time();
    return $entry->{value};
}

sub _cache_set {
    my ($key, $value, $ttl) = @_;
    $ttl //= $cache_ttl;
    $cache{$key} = {
        value   => $value,
        expires => time() + $ttl,
    };
    return $value;
}

sub _cache_clear {
    %cache = ();
}

# Rate limiting
sub _check_rate_limit {
    my ($ip) = @_;
    my $now = time();
    my $window_start = int($now / $rate_limit_window) * $rate_limit_window;

    my $key = "$ip:$window_start";

    # Cleanup old entries
    for my $k (keys %rate_limit) {
        delete $rate_limit{$k} if $k !~ /:$window_start$/;
    }

    $rate_limit{$key}++;
    return $rate_limit{$key} <= $rate_limit_max;
}

# Basic Auth check
sub _check_auth {
    my ($c) = @_;

    my $auth_config = $config->{auth} // {};
    return 1 unless $auth_config->{enabled};

    my $auth_header = $c->req->headers->authorization // '';

    # API Key auth
    if (my $api_key = $c->req->headers->header('X-API-Key')) {
        my $valid_keys = $auth_config->{api_keys} // [];
        return 1 if grep { $_ eq $api_key } @$valid_keys;
    }

    # Basic auth
    if ($auth_header =~ /^Basic\s+(.+)$/) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;

        my $users = $auth_config->{users} // {};
        if (exists $users->{$user} && $users->{$user} eq $pass) {
            return 1;
        }
    }

    return 0;
}

sub setup_routes {
    my ($self) = @_;

    $storage //= _build_storage();

    # Serve static files from web/public
    app->static->paths->[0] = '/app/web/public';

    # Global hooks
    app->hook(before_dispatch => sub ($c) {
        my $start = time();
        $c->stash(request_start => $start);

        # CORS
        $c->res->headers->header('Access-Control-Allow-Origin' => '*');
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key');

        if ($c->req->method eq 'OPTIONS') {
            $c->render(text => '', status => 200);
            return;
        }

        # Metrics
        $metrics{requests_total}++;
        my $path = $c->req->url->path->to_string;
        $path =~ s/\/[0-9a-f-]{36}/:id/g;  # Normalize UUIDs
        $metrics{requests_by_path}{$path}++;
    });

    app->hook(after_dispatch => sub ($c) {
        my $start = $c->stash('request_start');
        if ($start) {
            my $duration = time() - $start;
            $metrics{query_duration_sum} += $duration;
            $metrics{query_count}++;
        }
    });

    # API routes
    my $api = app->routes->under('/api');

    # Auth middleware for protected routes
    my $protected = $api->under('/' => sub ($c) {
        # Skip auth for health and metrics
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health|metrics)$};

        # Rate limiting
        my $ip = $c->tx->remote_address // '127.0.0.1';
        unless (_check_rate_limit($ip)) {
            $c->render(json => {
                error => 'Rate limit exceeded',
                retry_after => $rate_limit_window
            }, status => 429);
            $metrics{errors_total}++;
            return 0;
        }

        # Auth check
        unless (_check_auth($c)) {
            $c->res->headers->www_authenticate('Basic realm="Purl"');
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            $metrics{errors_total}++;
            return 0;
        }

        return 1;
    });

    # Health check (no auth required)
    $api->get('/health' => sub ($c) {
        my $ch_ok = eval { $storage->stats(); 1 } // 0;
        my $status = $ch_ok ? 'ok' : 'degraded';
        my $code = $ch_ok ? 200 : 503;

        $c->render(json => {
            status      => $status,
            timestamp   => time(),
            version     => $Purl::VERSION // '0.1.0',
            clickhouse  => $ch_ok ? 'connected' : 'disconnected',
            uptime_secs => int(time() - $metrics{start_time}),
        }, status => $code);
    });

    # Prometheus metrics (no auth required)
    $api->get('/metrics' => sub ($c) {
        my $stats = eval { $storage->stats() } // {};
        my $uptime = int(time() - $metrics{start_time});
        my $avg_duration = $metrics{query_count} > 0
            ? $metrics{query_duration_sum} / $metrics{query_count}
            : 0;

        my $output = <<"METRICS";
# HELP purl_info Purl server information
# TYPE purl_info gauge
purl_info{version="0.1.0"} 1

# HELP purl_uptime_seconds Server uptime in seconds
# TYPE purl_uptime_seconds counter
purl_uptime_seconds $uptime

# HELP purl_requests_total Total HTTP requests
# TYPE purl_requests_total counter
purl_requests_total $metrics{requests_total}

# HELP purl_errors_total Total errors
# TYPE purl_errors_total counter
purl_errors_total $metrics{errors_total}

# HELP purl_logs_ingested_total Total logs ingested
# TYPE purl_logs_ingested_total counter
purl_logs_ingested_total $metrics{logs_ingested}

# HELP purl_logs_stored Total logs in storage
# TYPE purl_logs_stored gauge
purl_logs_stored $stats->{total_logs}

# HELP purl_db_size_bytes Database size in bytes
# TYPE purl_db_size_bytes gauge
purl_db_size_bytes $stats->{db_size_bytes}

# HELP purl_query_duration_seconds_avg Average query duration
# TYPE purl_query_duration_seconds_avg gauge
purl_query_duration_seconds_avg $avg_duration

# HELP purl_cache_size Cache entries count
# TYPE purl_cache_size gauge
purl_cache_size @{[scalar keys %cache]}

# HELP purl_rate_limit_max Max requests per window
# TYPE purl_rate_limit_max gauge
purl_rate_limit_max $rate_limit_max
METRICS

        $c->render(text => $output, format => 'txt');
    });

    # Search logs (with caching)
    $protected->get('/logs' => sub ($c) {
        my $query   = $c->param('q') // '';
        my $from    = $c->param('from');
        my $to      = $c->param('to');
        my $level   = $c->param('level');
        my $service = $c->param('service');
        my $host    = $c->param('host');
        my $limit   = $c->param('limit') // 500;
        my $offset  = $c->param('offset') // 0;
        my $order   = $c->param('order') // 'DESC';

        if (my $range = $c->param('range')) {
            ($from, $to) = _parse_time_range($range);
        }

        my %params = (
            limit  => int($limit),
            offset => int($offset),
            order  => $order,
        );

        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;
        $params{host}    = $host if $host;

        # Parse KQL query
        if ($query) {
            if ($query =~ /^(\w+):(.+)$/) {
                my ($field, $value) = ($1, $2);
                $field = lc($field);
                $value =~ s/^["']|["']$//g;

                if ($field eq 'level') {
                    $params{level} = uc($value);
                } elsif ($field eq 'service') {
                    $params{service} = $value;
                } elsif ($field eq 'host') {
                    $params{host} = $value;
                } else {
                    $params{query} = $value;
                }
            } else {
                $params{query} = $query;
            }
        }

        # Check cache
        my $cache_key = md5_hex(encode_json(\%params));
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $results = $storage->search(%params);
        my $total = $storage->count(%params);

        my $response = {
            hits  => $results,
            total => $total,
            query => $query,
        };

        # Cache results (shorter TTL for real-time data)
        _cache_set($cache_key, $response, 10);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Ingest logs (POST)
    $protected->post('/logs' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $metrics{errors_total}++;
            $c->render(json => { error => 'Invalid JSON' }, status => 400);
            return;
        }

        my $logs = ref $body eq 'ARRAY' ? $body : [$body];
        my $count = 0;

        for my $log (@$logs) {
            $log->{timestamp} //= _epoch_to_iso(time());
            $log->{level} //= 'INFO';
            $log->{service} //= 'unknown';
            $log->{host} //= 'unknown';
            $log->{message} //= $log->{msg} // $log->{log} // '';
            $log->{raw} //= $log->{message};
            $log->{meta} //= {};

            $storage->insert($log);
            $count++;
        }

        $storage->flush() if $storage->can('flush');

        $metrics{logs_ingested} += $count;

        # Invalidate search cache on new data
        _cache_clear();

        # Broadcast to WebSocket subscribers
        _broadcast_logs($logs);

        $c->render(json => {
            status => 'ok',
            inserted => $count
        });
    });

    # KQL query endpoint (POST)
    $protected->post('/query' => sub ($c) {
        my $body = decode_json($c->req->body);

        my $query = $body->{query} // '';
        my $from  = $body->{from};
        my $to    = $body->{to};
        my $limit = $body->{limit} // 500;

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        if ($query) {
            $params{query} = $query;
        }

        my $results = $storage->search(%params);

        $c->render(json => {
            hits  => $results,
            total => scalar(@$results),
        });
    });

    # Field statistics (with caching)
    $protected->get('/stats/fields/:field' => sub ($c) {
        my $field = $c->param('field');
        my $limit = $c->param('limit') // 10;
        my $from  = $c->param('from');
        my $to    = $c->param('to');

        unless ($field =~ /^(level|service|host)$/) {
            $c->render(json => { error => 'Invalid field' }, status => 400);
            return;
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $cache_key = "field_stats:$field:" . md5_hex(encode_json(\%params));
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $storage->field_stats($field, %params);

        my $response = {
            field  => $field,
            values => $stats,
        };

        _cache_set($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Time histogram (with caching)
    $protected->get('/stats/histogram' => sub ($c) {
        my $interval = $c->param('interval') // '1 hour';
        my $from     = $c->param('from');
        my $to       = $c->param('to');
        my $level    = $c->param('level');
        my $service  = $c->param('service');

        my %params = (interval => $interval);
        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;

        my $cache_key = "histogram:" . md5_hex(encode_json(\%params));
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $histogram = $storage->histogram(%params);

        my $response = {
            interval => $interval,
            buckets  => $histogram,
        };

        _cache_set($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Available fields
    $protected->get('/fields' => sub ($c) {
        my $fields = $storage->get_fields();
        $c->render(json => { fields => $fields });
    });

    # Database stats
    $protected->get('/stats' => sub ($c) {
        my $cache_key = 'db_stats';
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $storage->stats();
        _cache_set($cache_key, $stats, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $stats);
    });

    # Configured sources
    $protected->get('/sources' => sub ($c) {
        my $sources = $config->{sources} // [];
        $c->render(json => { sources => $sources });
    });

    # WebSocket for live tail
    $api->websocket('/logs/stream' => sub ($c) {
        my $ws = $c->tx;

        push @$websockets, $ws;

        $c->on(message => sub ($c, $msg) {
            my $data = eval { decode_json($msg) };
            if ($data && $data->{type} eq 'subscribe') {
                $ws->{filter} = $data->{filter} // {};
            }
        });

        $c->on(finish => sub ($c, $code, $reason) {
            $websockets = [grep { $_ != $ws } @$websockets];
        });

        $c->send(encode_json({
            type    => 'connected',
            message => 'Connected to log stream',
        }));
    });

    # Cache management endpoints
    $protected->delete('/cache' => sub ($c) {
        _cache_clear();
        $c->render(json => { status => 'ok', message => 'Cache cleared' });
    });

    # ============================================
    # Saved Searches API
    # ============================================

    $protected->get('/saved-searches' => sub ($c) {
        my $searches = $storage->get_saved_searches();
        $c->render(json => { searches => $searches });
    });

    $protected->post('/saved-searches' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name} && $body->{query}) {
            $c->render(json => { error => 'Name and query required' }, status => 400);
            return;
        }

        $storage->create_saved_search($body->{name}, $body->{query}, $body->{time_range});
        $c->render(json => { status => 'ok' });
    });

    $protected->delete('/saved-searches/:id' => sub ($c) {
        my $id = $c->param('id');
        $storage->delete_saved_search($id);
        $c->render(json => { status => 'ok' });
    });

    # ============================================
    # Alerts API
    # ============================================

    $protected->get('/alerts' => sub ($c) {
        my $alerts = $storage->get_alerts();
        $c->render(json => { alerts => $alerts });
    });

    $protected->post('/alerts' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name}) {
            $c->render(json => { error => 'Name required' }, status => 400);
            return;
        }

        $storage->create_alert(%$body);
        $c->render(json => { status => 'ok' });
    });

    $protected->put('/alerts/:id' => sub ($c) {
        my $id = $c->param('id');
        my $body = eval { decode_json($c->req->body) };

        $storage->update_alert($id, %$body);
        $c->render(json => { status => 'ok' });
    });

    $protected->delete('/alerts/:id' => sub ($c) {
        my $id = $c->param('id');
        $storage->delete_alert($id);
        $c->render(json => { status => 'ok' });
    });

    $protected->post('/alerts/check' => sub ($c) {
        my $triggered = $storage->check_alerts();
        $c->render(json => { triggered => $triggered });
    });

    # Serve SPA for all other routes
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

# Broadcast logs to WebSocket subscribers
sub _broadcast_logs {
    my ($logs) = @_;

    for my $ws (@$websockets) {
        next unless $ws;
        eval {
            for my $log (@$logs) {
                my $filter = $ws->{filter} // {};

                # Apply filter
                next if $filter->{level} && $log->{level} ne $filter->{level};
                next if $filter->{service} && $log->{service} ne $filter->{service};

                $ws->send(encode_json({
                    type => 'log',
                    data => $log,
                }));
            }
        };
    }
}

# Parse time range shortcut (15m, 1h, 24h, 7d)
sub _parse_time_range {
    my ($range) = @_;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/) {
        $from = $now - ($1 * 86400);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = _epoch_to_iso($from);
    my $to_ts = _epoch_to_iso($now);

    return ($from_ts, $to_ts);
}

sub _epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Start the server
sub run {
    my ($self, %options) = @_;

    my $server_config = $config->{server} // {};

    my $host    = $options{host} // $server_config->{host} // '0.0.0.0';
    my $port    = $options{port} // $server_config->{port} // 3000;
    my $workers = $options{workers} // $server_config->{workers} // 4;

    $self->setup_routes();

    app->config(hypnotoad => {
        listen  => ["http://$host:$port"],
        workers => $workers,
    });

    app->log->level('info');
    app->log->info("Starting Purl server on http://$host:$port");

    app->start('daemon', '-l', "http://$host:$port");
}

1;

__END__

=head1 NAME

Purl::API::Server - Enterprise-grade Mojolicious REST API server

=head1 SYNOPSIS

    use Purl::API::Server;

    my $server = Purl::API::Server->new(
        config => $config,
    );

    $server->run(port => 3000);

=head1 FEATURES

=over 4

=item * Prometheus metrics at /api/metrics

=item * Basic Auth and API Key authentication

=item * Rate limiting (configurable requests/minute)

=item * In-memory query caching with TTL

=item * WebSocket live tail with filtering

=item * Health check with component status

=back

=head1 API ENDPOINTS

    GET  /api/health              - Health check (no auth)
    GET  /api/metrics             - Prometheus metrics (no auth)
    GET  /api/logs                - Search logs (cached)
    POST /api/logs                - Ingest logs
    POST /api/query               - KQL query
    GET  /api/stats/fields/:field - Field statistics (cached)
    GET  /api/stats/histogram     - Time histogram (cached)
    GET  /api/fields              - Available fields
    GET  /api/stats               - Database stats (cached)
    GET  /api/sources             - Configured log sources
    WS   /api/logs/stream         - Live log stream
    DELETE /api/cache             - Clear cache

=head1 CONFIGURATION

    auth:
      enabled: true
      users:
        admin: secret123
      api_keys:
        - sk_live_xxxxx

    rate_limit:
      max_requests: 1000

    cache:
      ttl: 60

=cut

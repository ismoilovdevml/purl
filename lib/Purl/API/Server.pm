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
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::Config;

# Package-level state
my $storage;
my $config = {};
my $settings;  # Purl::Config instance
my $websockets = [];
my %notifiers;

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

sub _build_notifiers {
    %notifiers = ();

    # Telegram - check ENV first, then settings
    my $tg_token = $ENV{PURL_TELEGRAM_BOT_TOKEN}
        // ($settings ? $settings->get_nested('notifications', 'telegram', 'bot_token') : undef);
    my $tg_chat = $ENV{PURL_TELEGRAM_CHAT_ID}
        // ($settings ? $settings->get_nested('notifications', 'telegram', 'chat_id') : undef);

    if ($tg_token && $tg_chat) {
        $notifiers{telegram} = Purl::Alert::Telegram->new(
            name      => 'telegram',
            bot_token => $tg_token,
            chat_id   => $tg_chat,
        );
    }

    # Slack - check ENV first, then settings
    my $slack_webhook = $ENV{PURL_SLACK_WEBHOOK_URL}
        // ($settings ? $settings->get_nested('notifications', 'slack', 'webhook_url') : undef);
    my $slack_channel = $ENV{PURL_SLACK_CHANNEL}
        // ($settings ? $settings->get_nested('notifications', 'slack', 'channel') : '');

    if ($slack_webhook) {
        $notifiers{slack} = Purl::Alert::Slack->new(
            name        => 'slack',
            webhook_url => $slack_webhook,
            channel     => $slack_channel,
        );
    }

    # Custom webhook - check ENV first, then settings
    my $webhook_url = $ENV{PURL_ALERT_WEBHOOK_URL}
        // ($settings ? $settings->get_nested('notifications', 'webhook', 'url') : undef);
    my $webhook_token = $ENV{PURL_ALERT_WEBHOOK_TOKEN}
        // ($settings ? $settings->get_nested('notifications', 'webhook', 'auth_token') : '');

    if ($webhook_url) {
        $notifiers{webhook} = Purl::Alert::Webhook->new(
            name       => 'webhook',
            url        => $webhook_url,
            auth_token => $webhook_token,
        );
    }

    return \%notifiers;
}

sub _send_notifications {
    my ($alert, $context) = @_;

    my @sent;
    my $notify_type = $alert->{notify_type} // 'webhook';

    # Send to specific notifier if configured in alert
    if ($notify_type eq 'telegram' && $notifiers{telegram}) {
        if ($notifiers{telegram}->notify($alert, $context)) {
            push @sent, 'telegram';
        }
    }
    elsif ($notify_type eq 'slack' && $notifiers{slack}) {
        if ($notifiers{slack}->notify($alert, $context)) {
            push @sent, 'slack';
        }
    }
    elsif ($notify_type eq 'webhook') {
        # For webhook type, use target URL from alert or default webhook
        if ($alert->{notify_target}) {
            my $webhook = Purl::Alert::Webhook->new(
                name => 'alert-webhook',
                url  => $alert->{notify_target},
            );
            if ($webhook->notify($alert, $context)) {
                push @sent, 'webhook';
            }
        }
        elsif ($notifiers{webhook}) {
            if ($notifiers{webhook}->notify($alert, $context)) {
                push @sent, 'webhook';
            }
        }
    }

    return \@sent;
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

    # Check if auth is enabled via env or config
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;
    return 1 unless $auth_enabled;

    # Skip auth for requests from the web UI (same origin)
    # Check if request comes from the same host (web dashboard)
    my $referer = $c->req->headers->referrer // '';
    my $origin = $c->req->headers->origin // '';
    my $host = $c->req->url->to_abs->host_port;

    # If request has Referer or Origin from same host, skip auth (web UI request)
    if ($referer =~ m{^https?://\Q$host\E}i || $origin =~ m{^https?://\Q$host\E}i) {
        return 1;
    }

    # Also allow if X-Requested-With header indicates AJAX from same origin
    my $xhr = $c->req->headers->header('X-Requested-With') // '';
    my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
    if ($sec_fetch eq 'same-origin') {
        return 1;
    }

    my $auth_header = $c->req->headers->authorization // '';

    # API Key auth (env or config)
    if (my $api_key = $c->req->headers->header('X-API-Key')) {
        # Check env API keys (comma-separated)
        if (my $env_keys = $ENV{PURL_API_KEYS}) {
            my @keys = split /,/, $env_keys;
            return 1 if grep { $_ eq $api_key } @keys;
        }
        # Check config API keys
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

    # Initialize config manager
    $settings //= Purl::Config->new();

    $storage //= _build_storage();
    _build_notifiers();

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

    # JSON metrics endpoint (for dashboard)
    $api->get('/metrics/json' => sub ($c) {
        my $stats = eval { $storage->stats() } // {};
        my $ch_metrics = eval { $storage->get_metrics() } // {};
        my $uptime = int(time() - $metrics{start_time});
        my $avg_duration = $metrics{query_count} > 0
            ? sprintf('%.3f', $metrics{query_duration_sum} / $metrics{query_count})
            : 0;

        $c->render(json => {
            server => {
                version       => '0.1.0',
                uptime_secs   => $uptime,
                uptime_human  => _format_duration($uptime),
            },
            requests => {
                total         => $metrics{requests_total},
                errors        => $metrics{errors_total},
                avg_duration  => $avg_duration,
                by_path       => $metrics{requests_by_path},
            },
            storage => {
                total_logs    => $stats->{total_logs} // 0,
                db_size_mb    => $stats->{db_size_mb} // 0,
                oldest_log    => $stats->{oldest_log},
                newest_log    => $stats->{newest_log},
            },
            clickhouse => {
                queries_total   => $ch_metrics->{queries_total} // 0,
                queries_cached  => $ch_metrics->{queries_cached} // 0,
                cache_hit_rate  => $ch_metrics->{cache_hit_rate} // '0%',
                avg_query_time  => $ch_metrics->{avg_query_time} // '0s',
                inserts_total   => $ch_metrics->{inserts_total} // 0,
                bytes_inserted  => $ch_metrics->{bytes_inserted} // 0,
                buffer_size     => $ch_metrics->{buffer_size} // 0,
                errors_total    => $ch_metrics->{errors_total} // 0,
            },
            ingestion => {
                logs_ingested => $metrics{logs_ingested},
            },
            cache => {
                entries       => scalar keys %cache,
                ttl_seconds   => $cache_ttl,
            },
        });
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

    # ============================================
    # Analytics API
    # ============================================

    # Table statistics
    $protected->get('/analytics/tables' => sub ($c) {
        my $cache_key = 'analytics_tables';
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $tables = $storage->get_table_stats();
        my $response = { tables => $tables };

        _cache_set($cache_key, $response, 60);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Recent slow queries
    $protected->get('/analytics/queries' => sub ($c) {
        my $limit = $c->param('limit') // 10;

        my $cache_key = "analytics_queries:$limit";
        if (my $cached = _cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $queries = $storage->get_slow_queries(int($limit));
        my $response = { queries => $queries };

        _cache_set($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Notifier status
    $protected->get('/analytics/notifiers' => sub ($c) {
        my %status;
        for my $type (keys %notifiers) {
            $status{$type} = {
                configured => 1,
                name       => $notifiers{$type}->name,
            };
        }

        $c->render(json => {
            notifiers => \%status,
            available => [qw(telegram slack webhook)],
        });
    });

    # ============================================
    # Server Configuration API
    # ============================================

    # Get current server configuration (read-only, from env)
    $protected->get('/config' => sub ($c) {
        my $storage_config = $config->{storage} // {};
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
                # password is masked for security
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

    # Get current retention settings
    $protected->get('/config/retention' => sub ($c) {
        my $days = $ENV{PURL_RETENTION_DAYS} // $config->{storage}{retention_days} // 30;
        my $stats = eval { $storage->stats() } // {};

        $c->render(json => {
            retention_days => int($days),
            oldest_log     => $stats->{oldest_log},
            newest_log     => $stats->{newest_log},
            total_logs     => $stats->{total_logs} // 0,
            db_size_mb     => $stats->{db_size_mb} // 0,
        });
    });

    # Update retention (triggers TTL modification)
    $protected->put('/config/retention' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $c->render(json => { error => 'days required' }, status => 400);
            return;
        }

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $c->render(json => { error => 'days must be between 1 and 365' }, status => 400);
            return;
        }

        # Update retention in storage
        my $result = eval { $storage->update_retention($days) };
        if ($@) {
            $c->render(json => { error => "Failed to update retention: $@" }, status => 500);
            return;
        }

        $c->render(json => {
            status         => 'ok',
            retention_days => $days,
            message        => "Retention updated to $days days. Note: Set PURL_RETENTION_DAYS=$days in .env for persistence.",
        });
    });

    # Test ClickHouse connection
    $protected->post('/config/test-clickhouse' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };

        # Use provided values or fall back to current config
        my $host     = $body->{host} // $ENV{PURL_CLICKHOUSE_HOST} // 'localhost';
        my $port     = $body->{port} // $ENV{PURL_CLICKHOUSE_PORT} // 8123;
        my $database = $body->{database} // $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl';
        my $user     = $body->{user} // $ENV{PURL_CLICKHOUSE_USER} // 'default';
        my $password = $body->{password} // $ENV{PURL_CLICKHOUSE_PASSWORD} // '';

        # Try to connect
        eval {
            require HTTP::Tiny;
            my $http = HTTP::Tiny->new(timeout => 5);
            my $url = "http://$host:$port/?query=" . _url_encode("SELECT 1");

            my %headers;
            if ($user && $password) {
                require MIME::Base64;
                $headers{'Authorization'} = 'Basic ' . MIME::Base64::encode_base64("$user:$password", '');
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

    # Configured sources
    $protected->get('/sources' => sub ($c) {
        my $sources = $config->{sources} // [];
        $c->render(json => { sources => $sources });
    });

    # ============================================
    # Settings Management API
    # ============================================

    # Get all settings with source info (env/file/default)
    $protected->get('/settings' => sub ($c) {
        my $all = $settings->get_all();

        # Add source info for each setting
        my $result = {
            clickhouse => {
                host     => { value => $all->{clickhouse}{host}, from_env => $settings->is_from_env('clickhouse', 'host') },
                port     => { value => $all->{clickhouse}{port}, from_env => $settings->is_from_env('clickhouse', 'port') },
                database => { value => $all->{clickhouse}{database}, from_env => $settings->is_from_env('clickhouse', 'database') },
                user     => { value => $all->{clickhouse}{user}, from_env => $settings->is_from_env('clickhouse', 'user') },
                password_set => { value => ($all->{clickhouse}{password} ? 1 : 0), from_env => $settings->is_from_env('clickhouse', 'password') },
            },
            retention => {
                days => { value => $all->{retention}{days}, from_env => $settings->is_from_env('retention', 'days') },
            },
            auth => {
                enabled => { value => $all->{auth}{enabled}, from_env => $settings->is_from_env('auth', 'enabled') },
            },
            notifications => {
                telegram => {
                    enabled   => $settings->get_nested('notifications', 'telegram', 'enabled') // 0,
                    bot_token => $settings->get_nested('notifications', 'telegram', 'bot_token') ? 1 : 0,
                    chat_id   => $settings->get_nested('notifications', 'telegram', 'chat_id') ? 1 : 0,
                    from_env  => $ENV{PURL_TELEGRAM_BOT_TOKEN} ? 1 : 0,
                },
                slack => {
                    enabled     => $settings->get_nested('notifications', 'slack', 'enabled') // 0,
                    webhook_set => $settings->get_nested('notifications', 'slack', 'webhook_url') ? 1 : 0,
                    channel     => $settings->get_nested('notifications', 'slack', 'channel') // '',
                    from_env    => $ENV{PURL_SLACK_WEBHOOK_URL} ? 1 : 0,
                },
                webhook => {
                    enabled   => $settings->get_nested('notifications', 'webhook', 'enabled') // 0,
                    url_set   => $settings->get_nested('notifications', 'webhook', 'url') ? 1 : 0,
                    from_env  => $ENV{PURL_ALERT_WEBHOOK_URL} ? 1 : 0,
                },
            },
        };

        $c->render(json => $result);
    });

    # Update ClickHouse settings
    $protected->put('/settings/clickhouse' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $c->render(json => { error => 'Invalid JSON' }, status => 400);
            return;
        }

        # Check which fields are from ENV (cannot modify)
        my @from_env;
        for my $key (qw(host port database user password)) {
            if ($settings->is_from_env('clickhouse', $key) && exists $body->{$key}) {
                push @from_env, $key;
            }
        }

        if (@from_env) {
            $c->render(json => {
                error => "Cannot modify ENV-configured values: " . join(', ', @from_env),
                from_env => \@from_env,
            }, status => 400);
            return;
        }

        # Update settings
        my $current = $settings->get_section('clickhouse');
        for my $key (qw(host port database user password)) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        if ($settings->set_section('clickhouse', $current)) {
            # Rebuild storage with new settings
            $storage = _build_storage();

            $c->render(json => {
                status  => 'ok',
                message => 'ClickHouse settings updated. Restart may be required for full effect.',
            });
        } else {
            $c->render(json => { error => 'Failed to save settings' }, status => 500);
        }
    });

    # Update notification settings
    $protected->put('/settings/notifications/:type' => sub ($c) {
        my $type = $c->param('type');
        my $body = eval { decode_json($c->req->body) };

        unless ($body) {
            $c->render(json => { error => 'Invalid JSON' }, status => 400);
            return;
        }

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $c->render(json => { error => 'Invalid notification type' }, status => 400);
            return;
        }

        # Check ENV override
        my %env_check = (
            telegram => 'PURL_TELEGRAM_BOT_TOKEN',
            slack    => 'PURL_SLACK_WEBHOOK_URL',
            webhook  => 'PURL_ALERT_WEBHOOK_URL',
        );

        if ($ENV{$env_check{$type}}) {
            $c->render(json => {
                error    => "Cannot modify - configured via environment variable",
                from_env => 1,
            }, status => 400);
            return;
        }

        # Get current notifications config
        my $notifications = $settings->_config->{notifications} // {};
        $notifications->{$type} = $body;

        if ($settings->set_section('notifications', $notifications)) {
            # Rebuild notifiers
            _build_notifiers();

            $c->render(json => {
                status  => 'ok',
                message => ucfirst($type) . ' notification settings updated.',
            });
        } else {
            $c->render(json => { error => 'Failed to save settings' }, status => 500);
        }
    });

    # Test notification
    $protected->post('/settings/notifications/:type/test' => sub ($c) {
        my $type = $c->param('type');

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $c->render(json => { error => 'Invalid notification type' }, status => 400);
            return;
        }

        # Rebuild notifiers to pick up latest settings
        _build_notifiers();

        unless ($notifiers{$type}) {
            $c->render(json => {
                success => 0,
                error   => ucfirst($type) . ' is not configured',
            }, status => 400);
            return;
        }

        my $result = eval { $notifiers{$type}->send_test() };
        if ($@ || !$result) {
            $c->render(json => {
                success => 0,
                error   => $@ // 'Test failed',
            });
        } else {
            $c->render(json => {
                success => 1,
                message => 'Test notification sent successfully',
            });
        }
    });

    # Update retention settings
    $protected->put('/settings/retention' => sub ($c) {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $c->render(json => { error => 'days required' }, status => 400);
            return;
        }

        if ($settings->is_from_env('retention', 'days')) {
            $c->render(json => {
                error    => 'Cannot modify - configured via PURL_RETENTION_DAYS',
                from_env => 1,
            }, status => 400);
            return;
        }

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $c->render(json => { error => 'days must be between 1 and 365' }, status => 400);
            return;
        }

        if ($settings->set('retention', 'days', $days)) {
            # Update ClickHouse TTL
            eval { $storage->update_retention($days) };

            $c->render(json => {
                status         => 'ok',
                retention_days => $days,
                message        => "Retention updated to $days days.",
            });
        } else {
            $c->render(json => { error => 'Failed to save settings' }, status => 500);
        }
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

        # Send notifications for each triggered alert
        my @notifications;
        for my $alert (@$triggered) {
            my $sent = _send_notifications($alert, { count => $alert->{count} });
            push @notifications, {
                alert  => $alert->{name},
                sent   => $sent,
            } if @$sent;
        }

        $c->render(json => {
            triggered     => $triggered,
            notifications => \@notifications,
        });
    });

    # Test notification endpoint
    $protected->post('/alerts/test-notification' => sub ($c) {
        my $type = $c->param('type') // 'telegram';

        unless ($notifiers{$type}) {
            return $c->render(
                json   => { error => "Notifier '$type' not configured" },
                status => 400
            );
        }

        my $result = $notifiers{$type}->send_test();
        $c->render(json => {
            success => $result ? 1 : 0,
            type    => $type,
        });
    });

    # Serve SPA for all other routes
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

# Broadcast logs to WebSocket subscribers (with server-side filtering)
sub _broadcast_logs {
    my ($logs) = @_;

    for my $ws (@$websockets) {
        next unless $ws;
        eval {
            my $filter = $ws->{filter} // {};

            for my $log (@$logs) {
                # Apply all filters server-side to reduce bandwidth

                # Level filter (exact match or array)
                if ($filter->{level}) {
                    if (ref $filter->{level} eq 'ARRAY') {
                        my %allowed = map { uc($_) => 1 } @{$filter->{level}};
                        next unless $allowed{uc($log->{level} // '')};
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

                $ws->send(encode_json({
                    type => 'log',
                    data => $log,
                }));
            }
        };
        if ($@) {
            # Remove dead connections
            $websockets = [grep { $_ != $ws } @$websockets];
        }
    }
}

# Format duration in human readable format
sub _format_duration {
    my ($secs) = @_;
    return '0s' unless $secs;

    my @parts;
    if ($secs >= 86400) {
        push @parts, int($secs / 86400) . 'd';
        $secs %= 86400;
    }
    if ($secs >= 3600) {
        push @parts, int($secs / 3600) . 'h';
        $secs %= 3600;
    }
    if ($secs >= 60) {
        push @parts, int($secs / 60) . 'm';
        $secs %= 60;
    }
    if ($secs > 0 && @parts < 2) {
        push @parts, $secs . 's';
    }

    return join(' ', @parts) || '0s';
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

sub _url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
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

Purl::API::Server - Mojolicious REST API server for Purl

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

package Purl::API::Server;
use strict;
use warnings;
use 5.024;

our $VERSION = '1.2.0';

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(decode_base64);
use Time::HiRes qw(time);

use Purl::Storage::ClickHouse;
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::Config;

# Controllers
use Purl::API::Controller::Logs;
use Purl::API::Controller::Traces;
use Purl::API::Controller::System;
use Purl::API::Controller::Analytics;
use Purl::API::Controller::Auth;
use Purl::API::Controller::Stats;
use Purl::API::Controller::Patterns;
use Purl::API::Controller::SavedSearches;
use Purl::API::Controller::Alerts;
use Purl::API::Controller::Settings;
use Purl::API::Controller::Config;

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

# Shared cache for all controllers
my %cache;
my $cache_ttl = 60;

# Rate limiting state
my %rate_limit;
my $rate_limit_window = 60;
my $rate_limit_max = 1000;

# Password verification helper
sub _verify_password {
    my ($password, $stored) = @_;
    return 0 unless $stored && $stored =~ /^([^\$]+)\$([a-f0-9]+)$/;
    my ($salt, $hash) = ($1, $2);
    my $check = sha256_hex($salt . $password . $salt);
    return 0 unless length($check) == length($hash);
    my $result = 0;
    $result |= ord(substr($check, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check)-1;
    return $result == 0;
}

sub create {
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

    # Telegram
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

    # Slack
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

    # Webhook
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

sub _check_rate_limit {
    my ($ip) = @_;
    my $now = time();
    my $window_start = int($now / $rate_limit_window) * $rate_limit_window;
    my $key = "$ip:$window_start";

    for my $k (keys %rate_limit) {
        delete $rate_limit{$k} if $k !~ /:$window_start$/;
    }

    $rate_limit{$key}++;
    return $rate_limit{$key} <= $rate_limit_max;
}

sub _check_auth {
    my ($c) = @_;
    my $auth_config = $config->{auth} // {};

    my $auth_enabled = $ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled} // 0;
    return 1 unless $auth_enabled;

    # Skip auth for same-origin requests
    my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
    return 1 if $sec_fetch eq 'same-origin' || $sec_fetch eq 'same-site';

    my $origin = $c->req->headers->header('Origin') // '';
    my $host = $c->req->headers->host // '';
    if ($origin && $host) {
        my ($origin_host) = $origin =~ m{^https?://([^/]+)};
        return 1 if $origin_host && $origin_host eq $host;
    }

    my $referer = $c->req->headers->header('Referer') // '';
    if ($referer && $host) {
        my ($referer_host) = $referer =~ m{^https?://([^/]+)};
        return 1 if $referer_host && $referer_host eq $host;
    }

    # API Key auth
    if (my $api_key = $c->req->headers->header('X-API-Key')) {
        if (my $env_keys = $ENV{PURL_API_KEYS}) {
            my @keys = split /,/, $env_keys;
            return 1 if grep { $_ eq $api_key } @keys;
        }
        my $valid_keys = $auth_config->{api_keys} // [];
        return 1 if grep { $_ eq $api_key } @$valid_keys;
    }

    # Basic auth
    my $auth_header = $c->req->headers->authorization // '';
    if ($auth_header =~ /^Basic\s+(.+)$/) {
        my $decoded = decode_base64($1);
        my ($user, $pass) = split /:/, $decoded, 2;
        my $users = $auth_config->{users} // {};
        if (exists $users->{$user}) {
            my $stored = $users->{$user};
            if ($stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/) {
                return 1 if _verify_password($pass, $stored);
            } else {
                app->log->warn("User '$user' has plaintext password - please hash it");
                return 1 if $stored eq $pass;
            }
        }
    }

    return 0;
}

sub setup_routes {
    my ($self) = @_;

    $settings //= Purl::Config->new();
    $storage //= _build_storage();
    _build_notifiers();

    # Common controller args
    my %c_args = (storage => $storage, config => $config, cache => \%cache);

    # Instantiate controllers
    my $sys_c    = Purl::API::Controller::System->new(%c_args);
    my $auth_c   = Purl::API::Controller::Auth->new(%c_args);
    my $traces_c = Purl::API::Controller::Traces->new(%c_args);
    my $analytics_c = Purl::API::Controller::Analytics->new(%c_args, notifier_list => \%notifiers);
    my $logs_c   = Purl::API::Controller::Logs->new(%c_args, websockets => $websockets);
    my $stats_c  = Purl::API::Controller::Stats->new(%c_args);
    my $patterns_c = Purl::API::Controller::Patterns->new(%c_args);
    my $saved_c  = Purl::API::Controller::SavedSearches->new(%c_args);
    my $alerts_c = Purl::API::Controller::Alerts->new(%c_args, notifiers => \%notifiers);
    my $settings_c = Purl::API::Controller::Settings->new(
        %c_args,
        settings          => $settings,
        notifiers         => \%notifiers,
        rebuild_notifiers => sub { _build_notifiers() },
        rebuild_storage   => sub { $storage = _build_storage() },
    );
    my $config_c = Purl::API::Controller::Config->new(%c_args, main_config => $config);

    # Periodic buffer flush
    Mojo::IOLoop->recurring(2 => sub {
        if ($storage && $storage->can('maybe_flush')) {
            eval { $storage->maybe_flush(); };
            app->log->error("Periodic buffer flush failed: $@") if $@;
        }
    });

    # Static files
    app->static->paths->[0] = '/app/web/public';

    # Security headers and CORS
    app->hook(before_dispatch => sub ($c) {
        my $start = time();
        $c->stash(request_start => $start);

        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options' => 'SAMEORIGIN');
        $c->res->headers->header('X-XSS-Protection' => '1; mode=block');
        $c->res->headers->header('Referrer-Policy' => 'strict-origin-when-cross-origin');
        $c->res->headers->header('Content-Security-Policy' =>
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:");

        my $origin = $c->req->headers->header('Origin') // '';
        if ($origin && $origin =~ /^https?:\/\/localhost(:\d+)?$/) {
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        } else {
            $c->res->headers->header('Access-Control-Allow-Origin' => '*');
        }
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key, X-CSRF-Token');

        if ($c->req->method eq 'OPTIONS') {
            $c->render(text => '', status => 200);
            return;
        }

        $metrics{requests_total}++;
        my $path = $c->req->url->path->to_string;
        $path =~ s/\/[0-9a-f-]{36}/:id/g;
        $metrics{requests_by_path}{$path}++;
    });

    # Request logging
    app->hook(after_dispatch => sub ($c) {
        my $start = $c->stash('request_start');
        my $duration = $start ? time() - $start : 0;
        $metrics{query_duration_sum} += $duration;
        $metrics{query_count}++;

        my $method = $c->req->method;
        my $path = $c->req->url->path->to_string;
        my $status = $c->res->code // 0;
        my $ip = $c->tx->remote_address // '-';
        my $duration_ms = sprintf("%.2f", $duration * 1000);

        my $log_level = $status >= 500 ? 'error' : ($status >= 400 ? 'warn' : 'info');
        app->log->$log_level("$ip - $method $path $status ${duration_ms}ms");

        $metrics{errors_total}++ if $status >= 400;
    });

    my $api = app->routes->under('/api');

    # Protected routes middleware
    my $protected = $api->under('/' => sub ($c) {
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health|metrics)$};

        my $ip = $c->tx->remote_address // '127.0.0.1';
        unless (_check_rate_limit($ip)) {
            $c->render(json => { error => 'Rate limit exceeded', retry_after => $rate_limit_window }, status => 429);
            $metrics{errors_total}++;
            return 0;
        }

        unless (_check_auth($c)) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            $metrics{errors_total}++;
            return 0;
        }

        return 1;
    });

    # ============================================
    # Public endpoints (no auth)
    # ============================================
    $api->get('/csrf-token' => sub ($c) { $auth_c->csrf_token($c) });
    $api->get('/health' => sub ($c) { $sys_c->health($c) });
    $api->get('/metrics' => sub ($c) { $sys_c->metrics($c) });
    $api->get('/metrics/json' => sub ($c) { $sys_c->metrics_json($c) });

    # ============================================
    # Log endpoints
    # ============================================
    $protected->get('/logs' => sub ($c) { $logs_c->search($c) });
    $protected->post('/logs' => sub ($c) { $logs_c->ingest($c) });
    $protected->get('/logs/:id/context' => sub ($c) { $logs_c->context($c) });
    $protected->post('/query' => sub ($c) { $logs_c->query($c) });

    # ============================================
    # Trace endpoints
    # ============================================
    $protected->get('/traces/:trace_id' => sub ($c) { $traces_c->get_trace($c) });
    $protected->get('/traces/:trace_id/timeline' => sub ($c) { $traces_c->get_trace_timeline($c) });
    $protected->get('/requests/:request_id' => sub ($c) { $traces_c->get_request($c) });

    # ============================================
    # Stats endpoints
    # ============================================
    $protected->get('/stats/fields/#field' => sub ($c) { $stats_c->field_stats($c) });
    $protected->get('/stats/histogram' => sub ($c) { $stats_c->histogram($c) });
    $protected->get('/fields' => sub ($c) { $stats_c->fields($c) });
    $protected->get('/stats' => sub ($c) { $stats_c->db_stats($c) });

    # ============================================
    # Analytics endpoints
    # ============================================
    $protected->get('/analytics/tables' => sub ($c) { $analytics_c->tables($c) });
    $protected->get('/analytics/queries' => sub ($c) { $analytics_c->queries($c) });
    $protected->get('/analytics/notifiers' => sub ($c) { $analytics_c->notifiers($c) });

    # ============================================
    # Pattern endpoints
    # ============================================
    $protected->get('/patterns' => sub ($c) { $patterns_c->list($c) });
    $protected->get('/patterns/:hash/logs' => sub ($c) { $patterns_c->logs($c) });
    $protected->get('/patterns/stats' => sub ($c) { $patterns_c->stats($c) });

    # ============================================
    # Saved Searches endpoints
    # ============================================
    $protected->get('/saved-searches' => sub ($c) { $saved_c->list($c) });
    $protected->post('/saved-searches' => sub ($c) { $saved_c->create($c) });
    $protected->delete('/saved-searches/:id' => sub ($c) { $saved_c->delete($c) });

    # ============================================
    # Alerts endpoints
    # ============================================
    $protected->get('/alerts' => sub ($c) { $alerts_c->list($c) });
    $protected->post('/alerts' => sub ($c) { $alerts_c->create($c) });
    $protected->put('/alerts/:id' => sub ($c) { $alerts_c->update($c) });
    $protected->delete('/alerts/:id' => sub ($c) { $alerts_c->delete($c) });
    $protected->post('/alerts/check' => sub ($c) { $alerts_c->check($c) });
    $protected->post('/alerts/test-notification' => sub ($c) { $alerts_c->test_notification($c) });

    # ============================================
    # Config endpoints
    # ============================================
    $protected->get('/config' => sub ($c) { $config_c->get_config($c) });
    $protected->get('/config/retention' => sub ($c) { $config_c->get_retention($c) });
    $protected->put('/config/retention' => sub ($c) { $config_c->update_retention($c) });
    $protected->post('/config/test-clickhouse' => sub ($c) { $config_c->test_clickhouse($c) });
    $protected->get('/sources' => sub ($c) { $config_c->get_sources($c) });
    $protected->delete('/cache' => sub ($c) { $config_c->clear_cache($c) });

    # ============================================
    # Settings endpoints
    # ============================================
    $protected->get('/settings' => sub ($c) { $settings_c->get_all($c) });
    $protected->put('/settings/clickhouse' => sub ($c) { $settings_c->update_clickhouse($c) });
    $protected->put('/settings/notifications/:type' => sub ($c) { $settings_c->update_notifications($c) });
    $protected->post('/settings/notifications/:type/test' => sub ($c) { $settings_c->test_notification($c) });
    $protected->put('/settings/retention' => sub ($c) { $settings_c->update_retention($c) });

    # ============================================
    # WebSocket for live tail
    # ============================================
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

    # SPA fallback
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

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

    my $shutdown = sub {
        my $sig = shift;
        app->log->info("Received $sig signal, shutting down gracefully...");

        if ($storage && $storage->can('flush')) {
            app->log->info("Flushing log buffer...");
            eval { $storage->flush(); };
            app->log->error("Buffer flush failed: $@") if $@;
        }

        if (@$websockets) {
            app->log->info("Closing " . scalar(@$websockets) . " WebSocket connections...");
            for my $tx (@$websockets) {
                eval { $tx->finish(1001 => 'Server shutting down'); };
            }
        }

        app->log->info("Shutdown complete");
        exit 0;
    };

    ## no critic (Variables::RequireLocalizedPunctuationVars)
    $SIG{TERM} = sub { $shutdown->('SIGTERM') };
    $SIG{INT}  = sub { $shutdown->('SIGINT') };
    ## use critic

    app->start('daemon', '-l', "http://$host:$port");
}

1;

__END__

=head1 NAME

Purl::API::Server - Mojolicious REST API server for Purl

=head1 SYNOPSIS

    use Purl::API::Server;

    my $server = Purl::API::Server->create(config => $config);
    $server->run(port => 3000);

=head1 DESCRIPTION

Main API server that routes requests to specialized controllers:

    Purl::API::Controller::Logs        - Log search/ingest
    Purl::API::Controller::Traces      - Trace correlation
    Purl::API::Controller::System      - Health/metrics
    Purl::API::Controller::Analytics   - Table stats, slow queries
    Purl::API::Controller::Auth        - CSRF tokens
    Purl::API::Controller::Stats       - Field stats, histograms
    Purl::API::Controller::Patterns    - Log pattern analysis
    Purl::API::Controller::SavedSearches - Saved search CRUD
    Purl::API::Controller::Alerts      - Alert management
    Purl::API::Controller::Settings    - Runtime settings
    Purl::API::Controller::Config      - Read-only configuration

=cut

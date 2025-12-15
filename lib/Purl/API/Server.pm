package Purl::API::Server;
use strict;
use warnings;
use 5.024;

our $VERSION = '1.2.0';

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Digest::MD5 qw(md5_hex);
use Time::HiRes qw(time);

use Purl::Storage::ClickHouse;
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::Config;
use Purl::Utils qw(parse_time_range);
use Purl::API::Middleware qw(
    set_config
    check_auth
    check_rate_limit
    get_rate_limit_info
    verify_csrf_token
    cache_get
    cache_set
    cache_clear
);

# Controllers
use Purl::API::Controller::System;
use Purl::API::Controller::Analytics;
use Purl::API::Controller::Auth;
use Purl::API::Controller::Logs;
use Purl::API::Controller::Traces;

# Routes
use Purl::API::Routes::Config qw(setup_config_routes);
use Purl::API::Routes::Settings qw(setup_settings_routes);
use Purl::API::Routes::Patterns qw(setup_pattern_routes);
use Purl::API::Routes::WebSocket qw(setup_websocket_routes);
use Purl::API::Routes::Stats qw(setup_stats_routes);
use Purl::API::Routes::Alerts qw(setup_alert_routes);
use Purl::API::Routes::SavedSearches qw(setup_saved_search_routes);

# Package-level state
my $storage;
my $config = {};
my $settings;
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

sub create {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    set_config($config);
    return bless {}, $class;
}

sub _build_storage {
    my $storage_config = $config->{storage} // {};
    my $retention_days = $storage_config->{retention_days} // 30;
    my $ch_config = $storage_config->{clickhouse} // {};
    $storage = Purl::Storage::ClickHouse->new(
        host           => $ENV{PURL_CLICKHOUSE_HOST} // $ch_config->{host} // 'localhost',
        port           => $ENV{PURL_CLICKHOUSE_PORT} // $ch_config->{port} // 8123,
        database       => $ENV{PURL_CLICKHOUSE_DATABASE} // $ch_config->{database} // 'purl',
        username       => $ENV{PURL_CLICKHOUSE_USER} // $ch_config->{username} // 'default',
        password       => $ENV{PURL_CLICKHOUSE_PASSWORD} // $ch_config->{password} // '',
        buffer_size    => $ch_config->{buffer_size} // 1000,
        retention_days => $retention_days,
    );
    return $storage;
}

sub _build_notifiers {
    %notifiers = ();

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

    if ($notify_type eq 'telegram' && $notifiers{telegram}) {
        push @sent, 'telegram' if $notifiers{telegram}->notify($alert, $context);
    }
    elsif ($notify_type eq 'slack' && $notifiers{slack}) {
        push @sent, 'slack' if $notifiers{slack}->notify($alert, $context);
    }
    elsif ($notify_type eq 'webhook') {
        if ($alert->{notify_target}) {
            my $webhook = Purl::Alert::Webhook->new(name => 'alert-webhook', url => $alert->{notify_target});
            push @sent, 'webhook' if $webhook->notify($alert, $context);
        }
        elsif ($notifiers{webhook}) {
            push @sent, 'webhook' if $notifiers{webhook}->notify($alert, $context);
        }
    }

    return \@sent;
}

sub setup_routes {
    my ($self) = @_;

    $settings //= Purl::Config->new();
    $storage //= _build_storage();
    _build_notifiers();

    # Controllers
    my %c_args = (storage => $storage, config => $config);
    my $sys_c       = Purl::API::Controller::System->new(%c_args);
    my $auth_c      = Purl::API::Controller::Auth->new(%c_args);
    my $traces_c    = Purl::API::Controller::Traces->new(%c_args);
    my $analytics_c = Purl::API::Controller::Analytics->new(%c_args, notifier_list => \%notifiers);
    my $logs_c      = Purl::API::Controller::Logs->new(%c_args, websockets => $websockets);

    # Periodic buffer flush
    Mojo::IOLoop->recurring(2 => sub {
        eval { $storage->maybe_flush() } if $storage && $storage->can('maybe_flush');
    });

    app->static->paths->[0] = '/app/web/public';

    # Global hooks
    _setup_hooks();

    # API routes
    my $api = app->routes->under('/api');
    my $protected = _setup_auth_middleware($api);

    # ============================================
    # Public Routes (no auth)
    # ============================================
    $api->get('/csrf-token' => sub ($c) { $auth_c->csrf_token($c) });
    $api->get('/health' => sub ($c) { $sys_c->health($c) });
    $api->get('/metrics' => sub ($c) { $sys_c->metrics($c) });
    $api->get('/metrics/json' => sub ($c) { $sys_c->metrics_json($c) });

    # ============================================
    # Log Routes
    # ============================================
    $protected->get('/logs' => sub ($c) { $logs_c->search($c) });
    $protected->post('/logs' => sub ($c) { $logs_c->ingest($c) });
    $protected->get('/logs/:id/context' => sub ($c) { $logs_c->context($c) });
    $protected->post('/query' => sub ($c) { $logs_c->query($c) });

    # ============================================
    # Trace Routes
    # ============================================
    $protected->get('/traces/:trace_id' => sub ($c) { $traces_c->get_trace($c) });
    $protected->get('/traces/:trace_id/timeline' => sub ($c) { $traces_c->get_trace_timeline($c) });
    $protected->get('/requests/:request_id' => sub ($c) { $traces_c->get_request($c) });

    # ============================================
    # Analytics Routes
    # ============================================
    $protected->get('/analytics/tables' => sub ($c) { $analytics_c->tables($c) });
    $protected->get('/analytics/queries' => sub ($c) { $analytics_c->queries($c) });
    $protected->get('/analytics/notifiers' => sub ($c) { $analytics_c->notifiers($c) });

    # ============================================
    # Route Modules
    # ============================================
    setup_stats_routes($protected, { storage => $storage });
    setup_config_routes($protected, { storage => $storage, config => $config });
    setup_settings_routes($protected, {
        settings        => $settings,
        storage         => $storage,
        notifiers       => \%notifiers,
        build_storage   => \&_build_storage,
        build_notifiers => \&_build_notifiers,
    });
    setup_pattern_routes($protected, { storage => $storage });
    setup_saved_search_routes($protected, { storage => $storage });
    setup_alert_routes($protected, {
        storage            => $storage,
        notifiers          => \%notifiers,
        send_notifications => \&_send_notifications,
    });
    setup_websocket_routes($api, { websockets => $websockets });

    # Cache management
    $protected->delete('/cache' => sub ($c) {
        cache_clear();
        $c->render(json => { status => 'ok', message => 'Cache cleared' });
    });

    # SPA fallback
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

# ============================================
# Hook Setup
# ============================================

sub _setup_hooks {
    app->hook(before_dispatch => sub ($c) {
        my $start = time();
        $c->stash(request_start => $start);

        # Security headers
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options' => 'SAMEORIGIN');
        $c->res->headers->header('X-XSS-Protection' => '1; mode=block');
        $c->res->headers->header('Referrer-Policy' => 'strict-origin-when-cross-origin');
        $c->res->headers->header('Content-Security-Policy' =>
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self' ws: wss:");

        # CORS
        my $origin = $c->req->headers->header('Origin') // '';
        if ($origin && $origin =~ /^https?:\/\/localhost(:\d+)?$/) {
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        } else {
            $c->res->headers->header('Access-Control-Allow-Origin' => '*');
        }
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key, X-CSRF-Token');

        return $c->render(text => '', status => 200) if $c->req->method eq 'OPTIONS';

        # CSRF protection
        my $method = $c->req->method;
        my $sec_fetch = $c->req->headers->header('Sec-Fetch-Site') // '';
        if ($method =~ /^(POST|PUT|DELETE)$/ && ($sec_fetch eq 'same-origin' || $sec_fetch eq 'same-site')) {
            my $csrf_token = $c->req->headers->header('X-CSRF-Token') // '';
            unless (verify_csrf_token($csrf_token) || $c->req->headers->header('X-API-Key')) {
                app->log->warn("CSRF token validation failed for $method request");
            }
        }

        # Metrics
        $metrics{requests_total}++;
        my $path = $c->req->url->path->to_string;
        $path =~ s/\/[0-9a-f-]{36}/:id/g;
        $metrics{requests_by_path}{$path}++;
    });

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
}

sub _setup_auth_middleware {
    my ($api) = @_;
    return $api->under('/' => sub ($c) {
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health|metrics)$};

        my $ip = $c->tx->remote_address // '127.0.0.1';
        unless (check_rate_limit($ip)) {
            my $rate_info = get_rate_limit_info();
            $c->render(json => { error => 'Rate limit exceeded', retry_after => $rate_info->{window} }, status => 429);
            $metrics{errors_total}++;
            return 0;
        }

        unless (check_auth($c)) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            $metrics{errors_total}++;
            return 0;
        }

        return 1;
    });
}

sub run {
    my ($self, %options) = @_;
    my $server_config = $config->{server} // {};
    my $host = $options{host} // $server_config->{host} // '0.0.0.0';
    my $port = $options{port} // $server_config->{port} // 3000;
    my $workers = $options{workers} // $server_config->{workers} // 4;

    $self->setup_routes();

    app->config(hypnotoad => { listen => ["http://$host:$port"], workers => $workers });
    app->log->level('info');
    app->log->info("Starting Purl server on http://$host:$port");

    my $shutdown = sub {
        my $sig = shift;
        app->log->info("Received $sig, shutting down...");
        eval { $storage->flush() } if $storage && $storage->can('flush');
        for my $tx (@$websockets) { eval { $tx->finish(1001 => 'Server shutting down') } }
        app->log->info("Shutdown complete");
        exit 0;
    };

    local $SIG{TERM} = sub { $shutdown->('SIGTERM') };
    local $SIG{INT}  = sub { $shutdown->('SIGINT') };

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

=cut

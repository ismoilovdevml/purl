package Purl::API::Server;
use strict;
use warnings;
use 5.024;

our $VERSION = '1.2.0';

use Mojolicious::Lite -signatures;
use Mojo::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);

use Purl::Storage::ClickHouse;
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::Config;
use Purl::API::Middleware::Auth;
use Purl::API::Middleware::License;
use Purl::API::Middleware::LDAP;
use Purl::API::Middleware::SAML;
use Purl::API::Middleware::NamespaceScope;
use Purl::Broadcast::Local;

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
use Purl::API::Controller::Audit;
use Purl::API::Controller::Backup;
use Purl::API::Controller::OTLP;
use Purl::API::Controller::ESCompat;
use Purl::API::Controller::Syslog;
use Purl::API::Controller::Pipeline;
use Purl::API::Controller::Dashboard;
use Purl::API::Controller::K8sAudit;
use Purl::API::Controller::K8sHealth;
use Purl::API::Controller::AlertTemplates;
use Purl::API::Controller::AI;
use Purl::API::Controller::Clusters;

# Package-level state
my $storage;
my $config = {};
my $settings;  # Purl::Config instance
my $websockets = [];
my $broadcaster;
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
    # Extended metrics for Analytics - circular buffer for O(1) operations
    latencies          => [(0) x 1000],  # Pre-allocated circular buffer
    latency_index      => 0,             # Current write position
    latency_count      => 0,             # Number of entries (max 1000)
    bytes_in           => 0,
    bytes_out          => 0,
);

# Metrics accessor for controllers
sub get_metrics { return \%metrics; }

sub _build_ldap_middleware {
    my $ldap_config = $settings ? $settings->get_section('ldap') : {};
    my $ldap_enabled = $ENV{PURL_LDAP_ENABLED} // $ldap_config->{enabled} // 0;
    return undef unless $ldap_enabled;

    # Override config fields with ENV vars
    for my $key (qw(server port bind_dn bind_password search_base search_filter
                    tls_enabled tls_verify timeout mode user_attr mail_attr group_attr)) {
        my $env_var = 'PURL_LDAP_' . uc($key);
        $ldap_config->{$key} = $ENV{$env_var} if defined $ENV{$env_var} && $ENV{$env_var} ne '';
    }

    return Purl::API::Middleware::LDAP->new(config => $ldap_config);
}

sub _build_saml_middleware {
    my $saml_config  = $settings ? $settings->get_section('saml') : {};
    my $saml_enabled = $ENV{PURL_SAML_ENABLED} // $saml_config->{enabled} // 0;
    return undef unless $saml_enabled;

    for my $key (qw(entity_id idp_entity_id idp_sso_url idp_slo_url idp_cert
                    acs_url name_id_format sign_requests sp_cert sp_key
                    username_attr groups_attr allowed_groups force_authn)) {
        my $env_var = 'PURL_SAML_' . uc($key);
        $saml_config->{$key} = $ENV{$env_var}
            if defined $ENV{$env_var} && $ENV{$env_var} ne '';
    }

    return Purl::API::Middleware::SAML->new(config => $saml_config);
}

# Shared cache for all controllers
my %cache;
my $cache_ttl = 60;

# Auth middleware instance
my $auth_middleware;

# License middleware instance
my $license_middleware;

# LDAP middleware instance
my $ldap_middleware;

# SAML middleware instance
my $saml_middleware;

# Namespace scope middleware instance
my $namespace_scope;

sub create {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    $cache_ttl = $config->{cache}{ttl} // 60;
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

sub _build_broadcaster {
    my $redis_url = $ENV{PURL_REDIS_URL}
        // ($settings ? $settings->get('redis', 'url') : '');
    my $mode = $ENV{PURL_BROADCAST_MODE}
        // ($settings ? $settings->get('redis', 'mode') : 'auto');

    # Explicit local mode
    if ($mode eq 'local') {
        app->log->info("Broadcast: local mode (in-memory only)");
        return Purl::Broadcast::Local->new();
    }

    # Try Redis if URL is configured and mode is auto or redis
    if ($redis_url && $redis_url ne '') {
        my $redis_broadcaster;
        eval {
            require Purl::Broadcast::Redis;
            $redis_broadcaster = Purl::Broadcast::Redis->new(redis_url => $redis_url);
            if ($redis_broadcaster->is_connected) {
                app->log->info("Broadcast: Redis mode ($redis_url)");
            } else {
                app->log->warn("Broadcast: Redis configured but not connected, falling back to local");
                $redis_broadcaster = undef;
            }
        };
        if ($@) {
            app->log->warn("Broadcast: Redis init failed ($@), falling back to local");
        }
        return $redis_broadcaster if $redis_broadcaster;

        # If mode is explicitly redis but failed, still warn
        if ($mode eq 'redis') {
            app->log->warn("Broadcast: Redis mode requested but unavailable, using local fallback");
        }
    }

    # Default: local broadcast
    app->log->info("Broadcast: local mode (no Redis configured)");
    return Purl::Broadcast::Local->new();
}

sub setup_routes {
    my ($self) = @_;

    $settings //= Purl::Config->new();
    $storage //= _build_storage();
    _build_notifiers();
    $broadcaster //= _build_broadcaster();

    # Initialize auth middleware
    $auth_middleware = Purl::API::Middleware::Auth->new(
        config         => $config,
        rate_limit_max => $config->{rate_limit}{max_requests} // 1000,
    );

    # Initialize license middleware
    $license_middleware = Purl::API::Middleware::License->new(
        config   => $config,
        settings => $settings,
    );

    # Wire license middleware into auth for plan-aware authentication
    $auth_middleware->license_middleware($license_middleware);
    $auth_middleware->settings($settings);

    # Initialize LDAP middleware if configured
    $ldap_middleware = _build_ldap_middleware();
    $saml_middleware = _build_saml_middleware();

    # Initialize namespace scope middleware
    $namespace_scope = Purl::API::Middleware::NamespaceScope->new(
        settings => $settings,
    );

    # Activate license on startup
    my $license_key = $license_middleware->get_license_key();
    if ($license_key && $license_key ne '') {
        app->log->info("License key detected, activating...");
        my $license_info = $license_middleware->activate_with_api();
        if ($license_info->{valid} && $license_info->{activated}) {
            app->log->info("License activated: plan=$license_info->{plan}");
        } elsif ($license_info->{error}) {
            app->log->warn("License activation warning: $license_info->{error}");
            app->log->info("Running with plan: $license_info->{plan}");
        }
    } else {
        my $trial_info = $license_middleware->get_license_info();
        if ($trial_info && $trial_info->{trial}) {
            app->log->info("No license key — Pro trial active ($trial_info->{trial_days_remaining} days remaining)");
        } else {
            app->log->info("No license key configured, running as Free plan");
        }
    }

    # Session secret for signed cookies — persist across restarts
    my $session_secret = $ENV{PURL_SESSION_SECRET}
        // ($settings ? $settings->get('server', 'session_secret') : undef);
    if ($session_secret && $session_secret ne '') {
        app->log->info("Using persistent session secret");
    } else {
        $session_secret = join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..64);
        if ($settings) {
            $settings->set('server', 'session_secret', $session_secret);
            app->log->info("Generated and persisted new session secret to config");
        }
        app->log->warn("WARNING: Using ephemeral session secret — sessions won't survive restart. Set PURL_SESSION_SECRET env var for multi-replica deployments.");
    }
    app->secrets([$session_secret]);
    app->sessions->samesite('Strict');
    app->sessions->secure(1);

    # Create default admin for Pro/Enterprise if no users exist
    my $info = $license_middleware->get_license_info();
    if ($info && $info->{plan} ne 'free') {
        my $auth_section = $settings->get_section('auth') // {};
        my $users = $auth_section->{users} // {};
        if (!keys %$users) {
            my $default_hash = $auth_middleware->hash_password('admin');
            $auth_section->{users} = { admin => $default_hash };
            $auth_section->{enabled} = 1;
            $settings->set_section('auth', $auth_section);
            app->log->warn("Default admin user created (admin/admin). CHANGE PASSWORD IMMEDIATELY!");
        }
    }

    # Warn about default/weak passwords on startup
    my $auth_enabled = $ENV{PURL_AUTH_ENABLED}
        // ($settings ? $settings->get('auth', 'enabled') : 0) // 0;
    if ($auth_enabled) {
        my $auth_section = $settings->get_section('auth') // {};
        my $users = $auth_section->{users} // {};
        my @weak_passwords = qw(admin password 12345678 changeme admin123 password123 qwerty123);

        for my $username (sort keys %$users) {
            my $stored = $users->{$username};

            # Check hashed passwords against common weak passwords
            if ($stored && ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/)) {
                for my $weak (@weak_passwords) {
                    my ($is_weak) = $auth_middleware->verify_password($weak, $stored);
                    if ($is_weak) {
                        app->log->warn("Default password detected for user '$username'. Please change it immediately.");
                        last;
                    }
                }
            }
            # Check plaintext passwords (legacy format)
            elsif ($stored && grep { $stored eq $_ } @weak_passwords) {
                app->log->warn("Default password detected for user '$username'. Please change it immediately.");
            }
        }
    }

    # Common controller args
    my %c_args = (storage => $storage, config => $config, cache => \%cache, namespace_scope => $namespace_scope);

    # Instantiate controllers
    my $sys_c    = Purl::API::Controller::System->new(%c_args);
    my $auth_c   = Purl::API::Controller::Auth->new(
        %c_args,
        auth_middleware    => $auth_middleware,
        license_middleware => $license_middleware,
        ldap_middleware    => $ldap_middleware,
        saml_middleware    => $saml_middleware,
        settings           => $settings,
    );
    my $traces_c = Purl::API::Controller::Traces->new(%c_args);
    my $analytics_c = Purl::API::Controller::Analytics->new(%c_args, notifier_list => \%notifiers);
    my $logs_c   = Purl::API::Controller::Logs->new(%c_args, websockets => $websockets, broadcaster => $broadcaster);
    my $stats_c  = Purl::API::Controller::Stats->new(%c_args);
    my $patterns_c = Purl::API::Controller::Patterns->new(%c_args);
    my $saved_c  = Purl::API::Controller::SavedSearches->new(%c_args);
    my $alerts_c = Purl::API::Controller::Alerts->new(%c_args, notifiers => \%notifiers);
    my $settings_c;
    $settings_c = Purl::API::Controller::Settings->new(
        %c_args,
        settings          => $settings,
        notifiers         => \%notifiers,
        rebuild_notifiers => sub { _build_notifiers() },
        rebuild_storage   => sub { $storage = _build_storage() },
        reload_license    => sub {
            $license_middleware->_license_info(undef);
            $license_middleware->_cache_expires(0);
            my $key = $license_middleware->get_license_key();
            if ($key && $key ne '') {
                my $info = $license_middleware->activate_with_api();
                app->log->info("License reloaded: plan=$info->{plan}");
            } else {
                app->log->info("License key removed, reverting to Free plan");
            }
        },
        rebuild_ldap => sub {
            $ldap_middleware = _build_ldap_middleware();
            $settings_c->ldap_middleware($ldap_middleware) if $settings_c;
        },
        saml_middleware => $saml_middleware,
        rebuild_saml    => sub {
            $saml_middleware = _build_saml_middleware();
            $settings_c->saml_middleware($saml_middleware) if $settings_c;
            $auth_c->saml_middleware($saml_middleware)     if $auth_c;
        },
        auth_middleware    => $auth_middleware,
        ldap_middleware    => $ldap_middleware,
    );
    my $config_c = Purl::API::Controller::Config->new(%c_args, main_config => $config);
    my $audit_c  = Purl::API::Controller::Audit->new(%c_args);
    my $backup_c = Purl::API::Controller::Backup->new(%c_args);
    my $otlp_c      = Purl::API::Controller::OTLP->new(%c_args);
    my $escompat_c  = Purl::API::Controller::ESCompat->new(%c_args);
    my $syslog_c    = Purl::API::Controller::Syslog->new(%c_args);
    my $pipeline_c  = Purl::API::Controller::Pipeline->new(%c_args);
    my $dashboard_c = Purl::API::Controller::Dashboard->new(%c_args);
    my $k8saudit_c  = Purl::API::Controller::K8sAudit->new(%c_args);
    my $k8shealth_c      = Purl::API::Controller::K8sHealth->new(%c_args);
    my $alert_templates_c = Purl::API::Controller::AlertTemplates->new(%c_args);
    my $ai_c             = Purl::API::Controller::AI->new(%c_args, settings => $settings);
    my $clusters_c       = Purl::API::Controller::Clusters->new(%c_args);

    # Initialize audit schema (non-fatal)
    eval { $storage->_init_audit_schema() };
    app->log->warn("Audit schema init failed: $@") if $@;

    # Initialize backup schema (non-fatal)
    eval { $storage->_init_backup_schema() };
    app->log->warn("Backup schema init failed: $@") if $@;

    # Initialize pipeline schema (non-fatal)
    eval { $storage->_init_pipeline_schema() };
    app->log->warn("Pipeline schema init failed: $@") if $@;

    # Initialize dashboard schema (non-fatal)
    eval { $storage->_init_dashboard_schema() };
    app->log->warn("Dashboard schema init failed: $@") if $@;

    # Periodic buffer flush
    Mojo::IOLoop->recurring(2 => sub {
        if ($storage && $storage->can('maybe_flush')) {
            eval { $storage->maybe_flush(); };
            app->log->error("Periodic buffer flush failed: $@") if $@;
        }
    });

    # License heartbeat (every 6 hours)
    if ($license_key && $license_key ne '') {
        Mojo::IOLoop->recurring(21600 => sub {
            eval { $license_middleware->send_heartbeat(); };
            app->log->debug("License heartbeat sent") unless $@;
        });
    }

    # Static files
    app->static->paths->[0] = '/app/web/public';

    # Security headers and CORS
    app->hook(before_dispatch => sub ($c) {
        my $start = time();
        $c->stash(request_start => $start);

        # Core security headers
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options' => 'SAMEORIGIN');
        $c->res->headers->header('X-XSS-Protection' => '1; mode=block');
        $c->res->headers->header('Referrer-Policy' => 'strict-origin-when-cross-origin');

        # Comprehensive Content-Security-Policy
        $c->res->headers->header('Content-Security-Policy' => join('; ',
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "font-src 'self' data:",
            "connect-src 'self' ws: wss:",
            "frame-ancestors 'none'",
            "base-uri 'self'",
            "form-action 'self'",
        ));

        # Transport security
        $c->res->headers->header('Strict-Transport-Security' => 'max-age=31536000; includeSubDomains; preload');

        # Permissions policy — disable sensitive browser features
        $c->res->headers->header('Permissions-Policy' => 'camera=(), microphone=(), geolocation=(), payment=()');

        # Cross-origin isolation headers
        $c->res->headers->header('Cross-Origin-Opener-Policy' => 'same-origin');
        $c->res->headers->header('Cross-Origin-Resource-Policy' => 'same-origin');

        # Cross-Origin-Embedder-Policy only for non-static (API) requests
        my $path = $c->req->url->path->to_string;
        unless ($path =~ m{^/(?:assets|favicon|static)/} || $path =~ m{\.\w+$}) {
            $c->res->headers->header('Cross-Origin-Embedder-Policy' => 'require-corp');
        }

        # CORS — whitelist-based origin checking
        my $allowed_origins_str = $ENV{PURL_ALLOWED_ORIGINS}
            // 'http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173';
        my %allowed_origins = map { $_ => 1 } split(/\s*,\s*/, $allowed_origins_str);

        my $origin = $c->req->headers->header('Origin') // '';
        if ($origin && $allowed_origins{$origin}) {
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        } elsif ($origin && $origin =~ /^https?:\/\/(?:localhost|127\.0\.0\.1)(:\d+)?$/) {
            # Always allow localhost variants for development
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        }
        # No Access-Control-Allow-Origin header = browser blocks the request
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key, X-CSRF-Token');

        if ($c->req->method eq 'OPTIONS') {
            $c->render(text => '', status => 200);
            return;
        }

        $metrics{requests_total}++;
        $path = $c->req->url->path->to_string;
        $path =~ s/\/[0-9a-f-]{36}/:id/g;
        $metrics{requests_by_path}{$path}++;
    });

    # Request logging and metrics collection
    app->hook(after_dispatch => sub ($c) {
        my $start = $c->stash('request_start');
        my $duration = $start ? time() - $start : 0;
        my $duration_ms = $duration * 1000;

        $metrics{query_duration_sum} += $duration;
        $metrics{query_count}++;

        # Track latencies for percentile calculation using O(1) circular buffer
        my $idx = $metrics{latency_index} % 1000;
        $metrics{latencies}[$idx] = $duration_ms;
        $metrics{latency_index}++;
        $metrics{latency_count}++ if $metrics{latency_count} < 1000;

        # Track bytes
        my $req_size = length($c->req->body // '');
        my $res_size = length($c->res->body // '');
        $metrics{bytes_in} += $req_size;
        $metrics{bytes_out} += $res_size;

        my $method = $c->req->method;
        my $path = $c->req->url->path->to_string;
        my $status = $c->res->code // 0;
        my $ip = $c->tx->remote_address // '-';

        my $log_level = $status >= 500 ? 'error' : ($status >= 400 ? 'warn' : 'info');
        app->log->$log_level(sprintf("%s - %s %s %d %.2fms", $ip, $method, $path, $status, $duration_ms));

        $metrics{errors_total}++ if $status >= 400;
    });

    # Audit event helper — fire-and-forget, never breaks the app
    app->helper(audit_event => sub {
        my ($c, %args) = @_;
        eval {
            $c->app->storage->log_audit_event({
                actor         => $args{actor} // $c->session('username') // 'system',
                action        => $args{action},
                resource_type => $args{resource_type} // '',
                resource_id   => $args{resource_id}   // '',
                details       => $args{details}        // '',
                ip_address    => $c->tx->remote_address // '',
                status        => $args{status}         // 'success',
            });
        };
    });

    my $api = app->routes->under('/api');

    # Protected routes middleware
    my $protected = $api->under('/' => sub ($c) {
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health|metrics)$};

        my $ip = $c->tx->remote_address // '127.0.0.1';

        # Rate limiting via middleware
        unless ($auth_middleware->check_rate_limit($ip)) {
            $c->render(json => {
                error       => 'Rate limit exceeded',
                retry_after => $auth_middleware->rate_limit_window,
            }, status => 429);
            $metrics{errors_total}++;
            return 0;
        }

        # Add rate limit headers
        $c->res->headers->header('X-RateLimit-Limit' => $auth_middleware->rate_limit_max);
        $c->res->headers->header('X-RateLimit-Remaining' => $auth_middleware->get_rate_limit_remaining($ip));

        # Auth check via middleware
        unless ($auth_middleware->check_auth($c)) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            $metrics{errors_total}++;
            return 0;
        }

        # Attach license info to request stash
        $license_middleware->check_license($c);

        # Block access if password change required (except for the change-password endpoint itself)
        if ($c->session->{must_change_password} && $path !~ m{^/api/auth/(change-password|me|logout)$}) {
            $c->render(json => {
                error => 'Password change required',
                password_change_required => \1,
            }, status => 403);
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

    # Auth endpoints (public - no auth required)
    $api->post('/auth/login' => sub ($c) { $auth_c->login($c) });
    $api->post('/auth/logout' => sub ($c) { $auth_c->logout($c) });
    $api->get('/auth/me' => sub ($c) { $auth_c->me($c) });

    # Password change (requires auth — protected route)
    $protected->post('/auth/change-password' => sub ($c) { $auth_c->change_password($c) });

    # SSO/SAML 2.0 endpoints (public — no auth required)
    $api->get('/auth/sso/login'     => sub ($c) { $auth_c->sso_login($c) });
    $api->post('/auth/sso/callback' => sub ($c) { $auth_c->sso_callback($c) });
    $api->get('/auth/sso/metadata'  => sub ($c) { $auth_c->sso_metadata($c) });

    # ============================================
    # License endpoint (public - needed before auth to determine plan)
    # ============================================
    $api->get('/license' => sub ($c) {
        my $info = $license_middleware->get_license_info();
        $c->render(json => {
            plan       => $info->{plan} // 'free',
            features   => $info->{features} // [],
            limits     => $info->{limits} // {},
            activated  => $info->{activated} // 0,
            valid      => $info->{valid} // 0,
            expires_at => $info->{expires_at} // undef,
            ($info->{error} ? (error => $info->{error}) : ()),
            ($info->{trial} ? (
                trial                => \1,
                trial_days_remaining => $info->{trial_days_remaining},
                trial_expires_at     => $info->{trial_expires_at},
                trial_started_at     => $info->{trial_started_at},
            ) : ()),
        });
    });

    # ============================================
    # Log endpoints
    # ============================================
    $protected->get('/logs' => sub ($c) { $logs_c->search($c) });
    $protected->post('/logs' => sub ($c) { $logs_c->ingest($c) });
    $protected->get('/logs/:id/context' => sub ($c) { $logs_c->context($c) });
    $protected->post('/query' => sub ($c) { $logs_c->query($c) });

    # ============================================
    # OTLP ingest endpoints
    # ============================================
    $protected->post('/v1/otlp/logs' => sub ($c) { $otlp_c->ingest($c) });

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
    $protected->delete('/saved-searches/:id' => sub ($c) { $saved_c->remove($c) });

    # ============================================
    # Alerts endpoints
    # ============================================
    $protected->get('/alerts' => sub ($c) { $alerts_c->list($c) });
    $protected->post('/alerts' => sub ($c) { $alerts_c->create($c) });
    $protected->put('/alerts/:id' => sub ($c) { $alerts_c->update($c) });
    $protected->delete('/alerts/:id' => sub ($c) { $alerts_c->remove($c) });
    $protected->post('/alerts/check' => sub ($c) { $alerts_c->check($c) });
    $protected->post('/alerts/test-notification' => sub ($c) { $alerts_c->test_notification($c) });
    $protected->get('/alerts/templates' => sub ($c) { $alert_templates_c->list($c) });

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
    $protected->put('/settings/license' => sub ($c) { $settings_c->update_license($c) });

    # API key rotation endpoints
    $protected->get('/settings/api-keys' => sub ($c) { $settings_c->list_api_keys($c) });
    $protected->post('/settings/api-keys' => sub ($c) { $settings_c->generate_api_key($c) });
    $protected->delete('/settings/api-keys/:key_id' => sub ($c) { $settings_c->revoke_api_key($c) });

    # User management endpoints (Pro/Enterprise)
    $protected->get('/settings/users' => sub ($c) { $settings_c->list_users($c) });
    $protected->post('/settings/users' => sub ($c) { $settings_c->create_user($c) });
    $protected->put('/settings/users/:username' => sub ($c) { $settings_c->update_user($c) });
    $protected->delete('/settings/users/:username' => sub ($c) { $settings_c->delete_user($c) });

    # LDAP/AD configuration endpoints (Enterprise)
    $protected->get('/settings/ldap' => sub ($c) { $settings_c->get_ldap($c) });
    $protected->put('/settings/ldap' => sub ($c) { $settings_c->update_ldap($c) });
    $protected->post('/settings/ldap/test' => sub ($c) { $settings_c->test_ldap($c) });

    # SSO/SAML settings (Enterprise)
    $protected->get('/settings/sso'       => sub ($c) { $settings_c->get_sso($c) });
    $protected->put('/settings/sso'       => sub ($c) { $settings_c->update_sso($c) });
    $protected->post('/settings/sso/test' => sub ($c) { $settings_c->test_sso($c) });

    # ============================================
    # Backup endpoints
    # ============================================
    $protected->get('/backup' => sub ($c) { $backup_c->list($c) });
    $protected->post('/backup' => sub ($c) { $backup_c->create($c) });
    $protected->post('/backup/restore' => sub ($c) { $backup_c->restore($c) });
    $protected->delete('/backup/:id' => sub ($c) { $backup_c->remove($c) });

    # ============================================
    # Audit log endpoints (Enterprise)
    # ============================================
    $protected->get('/audit' => sub ($c) { $audit_c->list($c) });
    $protected->get('/audit/stats' => sub ($c) { $audit_c->stats($c) });

    # ============================================
    # Elasticsearch-compatible endpoints
    # ============================================
    $protected->post('/es/_search' => sub ($c) { $escompat_c->search($c) });
    $protected->post('/es/_msearch' => sub ($c) { $escompat_c->msearch($c) });
    $protected->get('/es/_field_caps' => sub ($c) { $escompat_c->field_caps($c) });

    # ============================================
    # Syslog ingest endpoint
    # ============================================
    $protected->post('/v1/syslog' => sub ($c) { $syslog_c->ingest($c) });

    # ============================================
    # Pipeline endpoints
    # ============================================
    $protected->get('/pipelines' => sub ($c) { $pipeline_c->list($c) });
    $protected->get('/pipelines/:id' => sub ($c) { $pipeline_c->get($c) });
    $protected->post('/pipelines' => sub ($c) { $pipeline_c->create($c) });
    $protected->put('/pipelines/:id' => sub ($c) { $pipeline_c->update($c) });
    $protected->delete('/pipelines/:id' => sub ($c) { $pipeline_c->remove($c) });
    $protected->post('/pipelines/test' => sub ($c) { $pipeline_c->test($c) });

    # ============================================
    # Dashboard endpoints
    # ============================================
    $protected->get('/dashboards' => sub ($c) { $dashboard_c->list($c) });
    $protected->get('/dashboards/templates' => sub ($c) { $dashboard_c->list_templates($c) });
    $protected->get('/dashboards/:id' => sub ($c) { $dashboard_c->get($c) });
    $protected->post('/dashboards' => sub ($c) { $dashboard_c->create($c) });
    $protected->post('/dashboards/from-template' => sub ($c) { $dashboard_c->create_from_template($c) });
    $protected->put('/dashboards/:id' => sub ($c) { $dashboard_c->update($c) });
    $protected->delete('/dashboards/:id' => sub ($c) { $dashboard_c->remove($c) });
    $protected->post('/dashboards/widget' => sub ($c) { $dashboard_c->execute_widget($c) });

    # ============================================
    # K8s Audit webhook endpoint
    # ============================================
    $protected->post('/v1/k8s-audit' => sub ($c) { $k8saudit_c->ingest($c) });

    # ============================================
    # K8s Health endpoints
    # ============================================
    $protected->get('/k8s/health' => sub ($c) { $k8shealth_c->summary($c) });
    $protected->get('/k8s/health/pods' => sub ($c) { $k8shealth_c->pods($c) });

    # ============================================
    # AI query endpoints
    # ============================================
    $protected->post('/ai/query' => sub ($c) { $ai_c->query($c) });
    $protected->get('/ai/suggest' => sub ($c) { $ai_c->suggest($c) });

    # ============================================
    # Clusters endpoint (multi-cluster support)
    # ============================================
    $protected->get('/clusters' => sub ($c) { $clusters_c->list($c) });

    # ============================================
    # WebSocket for live tail
    # ============================================
    $api->websocket('/logs/stream' => sub ($c) {
        my $ws = $c->tx;
        push @$websockets, $ws;

        # Subscribe to broadcast channel for cross-replica delivery
        my $sub_id;
        if ($broadcaster) {
            $sub_id = $broadcaster->subscribe(
                $broadcaster->default_channel,
                sub {
                    my ($json_msg) = @_;
                    eval {
                        my $logs = ref $json_msg ? $json_msg : decode_json($json_msg);
                        $logs = [$logs] unless ref $logs eq 'ARRAY';
                        my @matches = $logs_c->_filter_logs($ws->{filter} // {}, $logs);
                        if (@matches) {
                            $ws->send({json => \@matches});
                        }
                    };
                },
            );
        }

        $c->on(message => sub ($c, $msg) {
            my $data = eval { decode_json($msg) };
            if ($data && $data->{type} eq 'subscribe') {
                $ws->{filter} = $data->{filter} // {};
            }
        });

        $c->on(finish => sub ($c, $code, $reason) {
            # Unsubscribe from broadcast channel
            if ($broadcaster && defined $sub_id) {
                $broadcaster->unsubscribe($sub_id);
            }
            # Remove from local websockets array
            for my $i (0 .. $#$websockets) {
                if ($websockets->[$i] == $ws) {
                    splice @$websockets, $i, 1;
                    last;
                }
            }
        });

        my $mode = $broadcaster ? (ref($broadcaster) =~ /Redis/ ? 'redis' : 'local') : 'direct';
        $c->send(encode_json({
            type    => 'connected',
            message => 'Connected to log stream',
            broadcast_mode => $mode,
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

        # Step 1: Deactivate license first (free up activation slot)
        if ($license_middleware) {
            app->log->info("Deactivating license...");
            eval { $license_middleware->deactivate(); };
            app->log->error("License deactivation failed: $@") if $@;
        }

        # Step 2: Flush remaining log buffer
        if ($storage && $storage->can('flush')) {
            app->log->info("Flushing log buffer...");
            eval { $storage->flush(); };
            app->log->error("Buffer flush failed: $@") if $@;
        }

        # Step 3: Close WebSocket connections
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
    Purl::API::Controller::OTLP       - OpenTelemetry OTLP/JSON log ingest

=cut

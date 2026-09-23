package Purl::API::Server;
use strict;
use warnings;
use 5.024;

our $VERSION = '1.3.0';

use Mojolicious::Lite -signatures;
use Mojo::Server::Prefork ();
use Mojo::IOLoop ();
use Mojo::JSON qw(decode_json);
use Time::HiRes qw(time);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec ();
use Fcntl qw(:flock);
use Purl::Util::ClientIP ();
use Purl::Util::IngestRoutes qw(is_ingest_request);

use Purl::Storage::ClickHouse;
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::Config;
use Purl::API::Middleware::Auth;
use Purl::API::Middleware::LDAP;
use Purl::API::Middleware::SAML;
use Purl::API::Middleware::NamespaceScope;
use Purl::Broadcast::Prefork;
use Purl::API::LiveTail qw(send_connected send_logs handle_client_message);

# Controllers
use Purl::API::Controller::Logs;
use Purl::API::Controller::Traces;
use Purl::API::Controller::System;
use Purl::API::Controller::Analytics;
use Purl::API::Controller::Auth;
use Purl::API::Controller::SSOStatus;
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
use Purl::API::Controller::Agents;
use Purl::Metrics::Counters;

# Package-level state
my $storage;
my $config = {};
my $settings;  # Purl::Config instance
my $websockets = [];
my $broadcaster;
my %notifiers;
my $metrics_counters;   # Purl::Metrics::Counters (shared across workers)

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

# One 429 shape for every limiter: JSON body + Retry-After header carrying the
# seconds actually left in the caller's window, counted as an error.
sub _render_rate_limited {
    my ($c, $error, $retry_after) = @_;
    $c->res->headers->header('Retry-After' => $retry_after);
    $c->render(json => { error => $error, retry_after => $retry_after }, status => 429);
    $metrics{errors_total}++;
    return 0;
}

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

# Generate a high-entropy admin password (never a guessable default).
sub _generate_admin_password {
    my $bytes = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 24);
        close($fh);
    } else {
        $bytes = pack('C*', map { int(rand(256)) } 1..24);
    }
    # Alphanumeric alphabet — ~24 chars of entropy, no shell-hostile symbols.
    my @alpha = ('A'..'Z', 'a'..'z', 0..9);
    my $pw = '';
    $pw .= $alpha[ ord(substr($bytes, $_, 1)) % scalar(@alpha) ] for 0 .. length($bytes) - 1;
    return $pw;
}

# Persist the generated initial admin password to the config dir (chmod 600),
# so headless/container operators can retrieve it once. Best-effort.
sub _persist_initial_admin_password {
    my ($cfg, $password) = @_;
    return unless $cfg && $cfg->can('config_file');
    my $dir = dirname($cfg->config_file);
    eval {
        make_path($dir) unless -d $dir;
        my $path = "$dir/initial_admin_password.txt";
        open(my $fh, '>', $path) or die "open $path: $!";
        print $fh "username: admin\npassword: $password\n";
        close($fh);
        chmod 0600, $path;
        return $path;
    };
    return;
}

# Shared cache for all controllers
my %cache;
my $cache_ttl = 60;

# Trusted reverse-proxy list (arrayref), resolved once at startup.
my $trusted_proxies = [];

# Auth middleware instance
my $auth_middleware;

# LDAP middleware instance
my $ldap_middleware;

# SAML middleware instance
my $saml_middleware;

# Namespace scope middleware instance
my $namespace_scope;

# ---------------------------------------------------------------------------
# Singleton cron leadership (prefork-safe)
#
# setup_routes() runs in the prefork MANAGER, *before* build_prefork->run
# forks the workers. Any Mojo::IOLoop->recurring timer registered there is
# inherited by EVERY worker's event loop (the manager itself never starts its
# IOLoop -- it runs Mojo::Server::Prefork::_manage, a blocking manage/wait
# loop). So a host-wide singleton job (e.g. scheduled backup) registered
# pre-fork would fire once PER WORKER: N concurrent backups racing on the same dir / S3 prefix.
#
# We keep registering the timers pre-fork (so they exist in each worker) but
# gate the actual work behind an exclusive advisory file lock: exactly one
# worker can hold LOCK_EX at a time, and that worker becomes the "cron leader".
# The holder keeps the descriptor open for its lifetime. If it dies, the OS
# releases the lock automatically and another worker acquires it on its next
# election tick -- no manager<->worker IPC required, and self-healing.
#
# The per-worker 2s ingest-buffer flush is intentionally NOT gated (each worker
# owns its own buffer and must flush it).
our $CRON_LEADER_FH;   # defined only in the worker currently holding the lock

sub _cron_lock_path {
    return $ENV{PURL_CRON_LOCK_FILE}
        // File::Spec->catfile(File::Spec->tmpdir, 'purl-cron-leader.lock');
}

# Try to become (or confirm we already are) the singleton cron leader.
# Returns true iff THIS process currently holds the exclusive lock.
sub _acquire_cron_leadership {
    my ($lock_path) = @_;
    $lock_path //= _cron_lock_path();

    # Already leader: keep the descriptor open, stay leader.
    return 1 if $CRON_LEADER_FH;

    open my $fh, '>', $lock_path
        or do { app->log->warn("Cron lock open failed ($lock_path): $!"); return 0; };

    if (flock $fh, LOCK_EX | LOCK_NB) {
        $CRON_LEADER_FH = $fh;   # hold the lock for our process lifetime
        return 1;
    }

    close $fh;
    return 0;
}

# ============================================
# Server-side alert evaluation
# ============================================

# Resolve how often the alert timer runs, in seconds.
# ENV PURL_ALERT_CHECK_INTERVAL > settings alerts.check_interval_seconds > 60.
# Returns 0 to mean "disabled" (explicit 0, or any non-numeric/negative value).
# Values below MIN are raised to MIN: check_alerts() is a full pass over every
# alert rule against ClickHouse, so a 1s interval would be self-inflicted DoS.
my $ALERT_CHECK_MIN_INTERVAL = 10;

sub _alert_check_interval {
    my ($settings) = @_;

    # Go through Config::get rather than reading %ENV directly: it already owns
    # the ENV>settings>default precedence via %ENV_MAP and already treats an
    # empty-but-present env var as unset. Reading $ENV here instead made
    # PURL_ALERT_CHECK_INTERVAL="" — the normal result of templating an unset
    # Helm value — silently disable all alerting.
    my $raw = $settings ? $settings->get('alerts', 'check_interval_seconds') : undef;
    $raw = undef if defined $raw && $raw =~ /^\s*$/;
    $raw //= 60;

    $raw =~ s/^\s+|\s+$//g;
    return 0 unless $raw =~ /^\d+$/;
    return 0 if $raw == 0;
    return $raw < $ALERT_CHECK_MIN_INTERVAL ? $ALERT_CHECK_MIN_INTERVAL : $raw;
}

# One leader-gated alert evaluation tick.
#
# Returns undef when this process is NOT the cron leader — i.e. the check did
# not run here, which is exactly what stops N prefork workers from firing N
# duplicate Telegram messages. Otherwise returns the Scheduler result hashref,
# with an extra {error} key if evaluation threw (never propagates: a failing
# ClickHouse must not kill the IOLoop timer).
sub _run_alert_check {
    my ($scheduler, $lock_path) = @_;
    return undef unless $scheduler;
    return undef unless _acquire_cron_leadership($lock_path);

    my $result = eval { $scheduler->run_once() };
    return $result if ref $result eq 'HASH';
    return { triggered => [], notifications => [], error => ($@ || 'unknown error') };
}

sub create {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    $cache_ttl = $config->{cache}{ttl} // 60;
    return bless {}, $class;
}

# Read-only view of the effective config hashref handed to controllers
# (%c_args config => ...). Populated by create() and enriched by
# setup_routes() (env+file folding for pipeline/server). Used to assert the
# controller config contract, e.g. config->{pipeline} for the ReDoS guard.
sub effective_config { return $config }

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

    # Optional forum topic. Same ENV > file precedence as the pair above; the
    # channel drops it if it is not a valid topic id, so a bad value cannot
    # take the alert down with it.
    my $tg_thread = $ENV{PURL_TELEGRAM_THREAD_ID}
        // ($settings ? $settings->get_nested('notifications', 'telegram', 'thread_id') : undef);

    if ($tg_token && $tg_chat) {
        $notifiers{telegram} = Purl::Alert::Telegram->new(
            name      => 'telegram',
            bot_token => $tg_token,
            chat_id   => $tg_chat,
            thread_id => $tg_thread // '',
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

    # Explicit local mode: no Redis, one container. Still Prefork rather than
    # Broadcast::Local — "local" means "this container", and this container is
    # 4 forked workers, not one process (#64).
    if ($mode eq 'local') {
        app->log->info("Broadcast: local mode (cross-worker spool, no Redis)");
        return Purl::Broadcast::Prefork->new();
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

    # Default: cross-worker spool. Reaches every prefork worker in THIS
    # container; multi-replica deployments need PURL_REDIS_URL.
    app->log->info("Broadcast: local mode (cross-worker spool, no Redis configured)");
    return Purl::Broadcast::Prefork->new();
}

sub setup_routes {
    my ($self) = @_;

    $settings //= Purl::Config->new();

    # One-time cleanup (#52) of the ENV values older builds copied into
    # settings.json. Here, in the manager before any worker forks, so it runs
    # exactly once per start and every worker inherits the pruned file. It is
    # idempotent — after the first start it finds nothing and does not write.
    #
    # eval'd because a read-only config volume must not stop the server from
    # booting: failing to tidy a duplicate is not worth an outage.
    eval { $settings->prune_env_duplicates() };
    if ($@) {
        app->log->warn("Config: env-duplicate cleanup skipped: $@");
    }

    # Fold the fully-resolved config (ENV > file > defaults) for the
    # `pipeline` and `server` sections into the plain $config hashref that
    # is handed to controllers below (%c_args). In production the server is
    # started via `Purl::API::Server->create->run` with NO config argument,
    # so $config would otherwise be empty and controllers would never see
    # config->{pipeline} — the pipeline ReDoS guard (regex_timeout_ms /
    # regex_max_length) would silently ignore PURL_PIPELINE_REGEX_* env
    # overrides. `//=` per section means an explicitly-provided config
    # (e.g. from tests) is never clobbered. `server` is folded so run()
    # picks up server.workers / host / port from env+file too.
    for my $section (qw(pipeline server)) {
        $config->{$section} //= $settings->get_section($section);
    }

    $storage //= _build_storage();
    _build_notifiers();
    $broadcaster //= _build_broadcaster();

    # Initialize auth middleware
    $auth_middleware = Purl::API::Middleware::Auth->new(
        config         => $config,
        rate_limit_max => $config->{rate_limit}{max_requests} // 1000,
    );

    $auth_middleware->settings($settings);

    # Security posture from config: trusted proxies (for real client IP) + CSRF.
    $trusted_proxies = Purl::Util::ClientIP::parse_proxy_list(
        $settings->get('security', 'trusted_proxies') // ''
    );
    $auth_middleware->trusted_proxies($trusted_proxies);
    my $csrf_enabled = $settings->get('security', 'csrf_enabled');
    $csrf_enabled = 1 unless defined $csrf_enabled;
    $auth_middleware->csrf_enabled($csrf_enabled ? 1 : 0);

    # Initialize LDAP middleware if configured
    $ldap_middleware = _build_ldap_middleware();
    $saml_middleware = _build_saml_middleware();

    # Initialize namespace scope middleware
    $namespace_scope = Purl::API::Middleware::NamespaceScope->new(
        settings => $settings,
    );

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
    my $secure_cookies = $ENV{PURL_SECURE_COOKIES} // 0;
    app->sessions->secure($secure_cookies);
    app->log->info("Session cookies: secure=$secure_cookies, samesite=Strict");

    # Create default admin if no users exist
    {
        my $auth_section = $settings->get_section('auth') // {};
        my $users = $auth_section->{users} // {};
        if (!keys %$users) {
            my $admin_pass = $ENV{PURL_ADMIN_PASSWORD};
            my $generated  = 0;
            if (!defined $admin_pass || $admin_pass eq '') {
                # Never fall back to a guessable default — generate a strong one.
                $admin_pass = _generate_admin_password();
                $generated  = 1;
            }
            my $default_hash = $auth_middleware->hash_password($admin_pass);

            # Re-check under the lock. Two processes booting against the same
            # config directory must not each mint an admin and overwrite the
            # other's password — whoever gets the lock second finds a user and
            # leaves it alone.
            my $created = 0;
            $settings->update_section('auth', sub {
                my ($section) = @_;
                return if keys %{ $section->{users} // {} };
                $section->{users}   = { admin => $default_hash };
                $section->{enabled} = 1;
                $created = 1;
                return;
            });

            if (!$created) {
                app->log->info('Admin user already present; leaving the existing credentials alone.');
            } elsif ($generated) {
                _persist_initial_admin_password($settings, $admin_pass);
                app->log->warn('=' x 60);
                app->log->warn('INITIAL ADMIN CREDENTIALS (generated once, shown only now):');
                app->log->warn("    username: admin");
                app->log->warn("    password: $admin_pass");
                app->log->warn('Also written to <config_dir>/initial_admin_password.txt (chmod 600).');
                app->log->warn('Log in and change it, then delete that file.');
                app->log->warn('=' x 60);
            } else {
                app->log->info("Admin user created with password from PURL_ADMIN_PASSWORD env var");
            }
        }
    }

    # Warn about default/weak passwords on startup
    my $auth_enabled = $settings ? $settings->auth_enabled : 0;
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

    # Prometheus counters on the SHARED counter store (the same Redis-backed
    # store used for rate limiting and login lockout). Reusing it is the whole
    # point: %metrics below is per-worker, so a scrape of a prefork server sees
    # only one worker's slice of the truth.
    $metrics_counters = Purl::Metrics::Counters->new(
        store => $auth_middleware->counter_store,
    );

    # Instantiate controllers
    my $sys_c    = Purl::API::Controller::System->new(
        %c_args,
        metrics_counters => $metrics_counters,
    );
    my $auth_c   = Purl::API::Controller::Auth->new(
        %c_args,
        auth_middleware    => $auth_middleware,
        ldap_middleware    => $ldap_middleware,
        saml_middleware    => $saml_middleware,
        settings           => $settings,
    );
    my $sso_status_c = Purl::API::Controller::SSOStatus->new(
        %c_args,
        saml_middleware => $saml_middleware,
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
        rebuild_ldap => sub {
            $ldap_middleware = _build_ldap_middleware();
            $settings_c->ldap_middleware($ldap_middleware) if $settings_c;
        },
        saml_middleware => $saml_middleware,
        rebuild_saml    => sub {
            $saml_middleware = _build_saml_middleware();
            $settings_c->saml_middleware($saml_middleware) if $settings_c;
            $auth_c->saml_middleware($saml_middleware)     if $auth_c;
            $sso_status_c->saml_middleware($saml_middleware);
        },
        auth_middleware    => $auth_middleware,
        ldap_middleware    => $ldap_middleware,
    );
    my $config_c = Purl::API::Controller::Config->new(%c_args, main_config => $config);
    my $audit_c  = Purl::API::Controller::Audit->new(%c_args);
    my $backup_c = Purl::API::Controller::Backup->new(%c_args, settings => $settings);
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
    my $agents_c         = Purl::API::Controller::Agents->new(%c_args);

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

    # Initialize agents schema (non-fatal)
    eval { $storage->_init_agents_schema() };
    app->log->warn("Agents schema init failed: $@") if $@;

    # Periodic buffer flush -- DELIBERATELY per-worker. Each prefork worker owns
    # its own ingest buffer, so this MUST fire in EVERY worker. Do NOT gate it
    # behind cron leadership.
    Mojo::IOLoop->recurring(2 => sub {
        if ($storage && $storage->can('maybe_flush')) {
            eval { $storage->maybe_flush(); };
            app->log->error("Periodic buffer flush failed: $@") if $@;
        }
    });

    # Cron leader election / takeover tick. Cheap: one flock attempt while we
    # are not the leader, an immediate return once we are. Runs in every worker
    # so that if the current leader dies (OS drops its lock) another worker
    # takes over within one interval. See _acquire_cron_leadership().
    my $cron_lock_path = _cron_lock_path();
    Mojo::IOLoop->recurring(30 => sub {
        _acquire_cron_leadership($cron_lock_path);
    });

    # Scheduled backup (configurable interval, disabled by default)
    my $backup_schedule_enabled = $ENV{PURL_BACKUP_SCHEDULE_ENABLED}
        // ($settings ? $settings->get('backup', 'schedule_enabled') : 0);
    if ($backup_schedule_enabled) {
        my $backup_interval_hours = $ENV{PURL_BACKUP_SCHEDULE_INTERVAL_HOURS}
            // ($settings ? $settings->get('backup', 'schedule_interval_hours') : 24);
        my $backup_retention_days = $ENV{PURL_BACKUP_RETENTION_DAYS}
            // ($settings ? $settings->get('backup', 'retention_days') : 30);
        my $backup_dir = $ENV{PURL_BACKUP_DIR} // '/app/backups';
        my $interval_seconds = $backup_interval_hours * 3600;

        app->log->info("Scheduled backup enabled: every ${backup_interval_hours}h, retention ${backup_retention_days}d");

        # SINGLETON: leader worker only, so N workers do not launch N
        # concurrent backups racing on the same dir / S3 prefix (and one
        # worker's cleanup_old_backups cannot delete a backup another is
        # still writing).
        Mojo::IOLoop->recurring($interval_seconds => sub {
            return unless _acquire_cron_leadership($cron_lock_path);
            eval {
                require POSIX;
                app->log->info("Starting scheduled backup...");
                my $result = $storage->create_backup(
                    name       => 'scheduled_' . POSIX::strftime('%Y%m%d_%H%M%S', localtime),
                    backup_dir => $backup_dir,
                );
                app->log->info("Scheduled backup completed: id=$result->{id}, size=$result->{size_bytes}");

                # Auto-upload to S3 if enabled. Config resolution lives in
                # Purl::Storage::S3 so the scheduler, the controller and the
                # storage layer all agree on one bucket.
                require Purl::Storage::S3;
                my $s3_config = Purl::Storage::S3->config_from(settings => $settings);
                if ($s3_config->{enabled}) {
                    eval {
                        my $s3_result = $storage->upload_backup_to_s3($result->{id}, $s3_config);
                        app->log->info("Backup uploaded to S3: $s3_result->{target_path}");
                    };
                    app->log->error("S3 upload failed: $@") if $@;
                }

                # Auto-cleanup old backups. s3_config is passed so expired
                # backups are removed from the bucket too, not just from the
                # metadata table.
                my $cleaned = $storage->cleanup_old_backups(
                    $backup_retention_days,
                    s3_config => $s3_config,
                );
                app->log->info("Cleaned up $cleaned old backups") if $cleaned > 0;
            };
            app->log->error("Scheduled backup failed: $@") if $@;
        });
    }

    # Server-side alert evaluation.
    #
    # Without this timer check_alerts() ran ONLY from POST /api/alerts/check,
    # which only the dashboard calls — so closing the browser tab silently
    # stopped every Telegram/Slack/webhook notification. Alerting is a server
    # responsibility, not a browser one.
    #
    # SINGLETON: leader worker only (same gate as the backup timer), otherwise
    # N workers would each evaluate every rule and fire N duplicate messages.
    my $alert_interval = _alert_check_interval($settings);
    if ($alert_interval) {
        my $alert_scheduler = $alerts_c->scheduler;
        app->log->info("Server-side alert checks enabled: every ${alert_interval}s");
        # Evaluation and fan-out are both BLOCKING: check_alerts() is a
        # synchronous ClickHouse query and every notifier is a synchronous
        # HTTP::Tiny post (Telegram's timeout alone is 10s). Running that
        # inline would freeze the leader worker's event loop for the whole
        # tick — no requests served, no ingest buffer flushed, no WebSocket
        # serviced — for up to timeout x triggered-alert-count. A subprocess
        # keeps the blocking work off the loop; the leader lock is acquired in
        # the child so a stuck tick cannot also hold leadership hostage.
        my $alert_tick_running = 0;
        Mojo::IOLoop->recurring($alert_interval => sub {
            # Never overlap ticks: a fan-out slower than the interval would
            # otherwise pile up subprocesses and re-send the same alerts.
            return if $alert_tick_running;
            $alert_tick_running = 1;

            Mojo::IOLoop->subprocess(
                sub {
                    my $result = _run_alert_check($alert_scheduler, $cron_lock_path);
                    return $result // { skipped => 1 };
                },
                sub {
                    my ($subprocess, $err, $result) = @_;
                    $alert_tick_running = 0;

                    if ($err) {
                        app->log->error("Scheduled alert check subprocess failed: $err");
                        return;
                    }
                    return unless ref $result eq 'HASH';
                    return if $result->{skipped};     # not the leader this tick
                    if (my $rerr = $result->{error}) {
                        app->log->error("Scheduled alert check failed: $rerr");
                        return;
                    }
                    my $n = scalar @{ $result->{notifications} // [] };
                    app->log->info("Scheduled alert check sent $n notification(s)") if $n;
                }
            );
        });
    }
    else {
        app->log->info('Server-side alert checks DISABLED (alerts.check_interval_seconds = 0)');
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
        my $ip = ($auth_middleware ? $auth_middleware->client_ip($c) : $c->tx->remote_address) // '-';

        my $log_level = $status >= 500 ? 'error' : ($status >= 400 ? 'warn' : 'info');
        app->log->$log_level(sprintf("%s - %s %s %d %.2fms", $ip, $method, $path, $status, $duration_ms));

        $metrics{errors_total}++ if $status >= 400;

        # Mirror into the SHARED counters that /api/metrics exports. %metrics
        # above stays as-is for /api/metrics/json (per-worker latency
        # percentiles need the local circular buffer), but anything Prometheus
        # scrapes has to be fleet-wide or the numbers are fiction under prefork.
        if ($metrics_counters) {
            $metrics_counters->record_request(
                method      => $method,
                status      => $status,
                duration_ms => $duration_ms,
            );
            # Ingest volume, measured on the endpoints that actually accept
            # logs — total bytes_in would be dominated by dashboard traffic.
            $metrics_counters->record_ingest_bytes($req_size)
                if is_ingest_request($method, $path);
        }
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
                ip_address    => ($auth_middleware ? $auth_middleware->client_ip($c) : $c->tx->remote_address) // '',
                status        => $args{status}         // 'success',
            });
        };
    });

    my $api = app->routes->under('/api');

    # Protected routes middleware
    my $protected = $api->under('/' => sub ($c) {
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health(/live|/ready)?|metrics)$};

        my $ip = $auth_middleware->client_ip($c);

        # Rate limiting via middleware
        return _render_rate_limited($c, 'Rate limit exceeded',
            $auth_middleware->rate_limit_retry_after)
            unless $auth_middleware->check_rate_limit($ip);

        # Add rate limit headers
        $c->res->headers->header('X-RateLimit-Limit' => $auth_middleware->rate_limit_max);
        $c->res->headers->header('X-RateLimit-Remaining' => $auth_middleware->get_rate_limit_remaining($ip));

        # Auth check via middleware
        unless ($auth_middleware->check_auth($c)) {
            $c->render(json => { error => 'Unauthorized' }, status => 401);
            $metrics{errors_total}++;
            return 0;
        }

        # CSRF protection for cookie-authenticated (browser) mutating requests.
        # API-key / basic-auth clients and read-only methods are exempt.
        unless ($auth_middleware->check_csrf($c)) {
            $c->render(json => {
                error => 'CSRF token missing or invalid',
                csrf  => \1,
            }, status => 403);
            $metrics{errors_total}++;
            return 0;
        }

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
    # Split probes for Kubernetes. /live must NEVER depend on ClickHouse:
    # pointing a livenessProbe at a DB-backed endpoint turns a database outage
    # into a fleet-wide CrashLoopBackOff. /ready carries the dependency check.
    $api->get('/health/live'  => sub ($c) { $sys_c->health_live($c) });
    $api->get('/health/ready' => sub ($c) { $sys_c->health_ready($c) });
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
    # Is SSO on? The login page uses this to show the SSO button.
    $api->get('/auth/sso/status'    => sub ($c) { $sso_status_c->status($c) });

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
    $protected->get('/traces/recent' => sub ($c) { $traces_c->get_recent_traces($c) });
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

    # API key rotation endpoints
    $protected->get('/settings/api-keys' => sub ($c) { $settings_c->list_api_keys($c) });
    $protected->post('/settings/api-keys' => sub ($c) { $settings_c->generate_api_key($c) });
    $protected->delete('/settings/api-keys/:key_id' => sub ($c) { $settings_c->revoke_api_key($c) });

    # User management endpoints
    $protected->get('/settings/users' => sub ($c) { $settings_c->list_users($c) });
    $protected->post('/settings/users' => sub ($c) { $settings_c->create_user($c) });
    $protected->put('/settings/users/:username' => sub ($c) { $settings_c->update_user($c) });
    $protected->delete('/settings/users/:username' => sub ($c) { $settings_c->delete_user($c) });

    # LDAP/AD configuration endpoints
    $protected->get('/settings/ldap' => sub ($c) { $settings_c->get_ldap($c) });
    $protected->put('/settings/ldap' => sub ($c) { $settings_c->update_ldap($c) });
    $protected->post('/settings/ldap/test' => sub ($c) { $settings_c->test_ldap($c) });

    # SSO/SAML settings
    $protected->get('/settings/sso'       => sub ($c) { $settings_c->get_sso($c) });
    $protected->put('/settings/sso'       => sub ($c) { $settings_c->update_sso($c) });
    $protected->post('/settings/sso/test' => sub ($c) { $settings_c->test_sso($c) });

    # AI settings
    $protected->get('/settings/ai'        => sub ($c) { $settings_c->get_ai($c) });
    $protected->put('/settings/ai'        => sub ($c) { $settings_c->update_ai($c) });
    $protected->post('/settings/ai/test'  => sub ($c) { $settings_c->test_ai($c) });

    # Redis / Broadcast settings
    $protected->get('/settings/redis' => sub ($c) { $settings_c->get_redis($c) });
    $protected->put('/settings/redis' => sub ($c) { $settings_c->update_redis($c) });

    # ============================================
    # Agent management endpoints
    # ============================================
    $protected->get('/agents'              => sub ($c) { $agents_c->list($c) });
    $protected->post('/agents/register'    => sub ($c) { $agents_c->register($c) });
    $protected->post('/agents/heartbeat'   => sub ($c) { $agents_c->heartbeat($c) });
    $protected->delete('/agents/:id'       => sub ($c) { $agents_c->remove($c) });

    # ============================================
    # Backup endpoints
    # ============================================
    $protected->get('/backup/schedule' => sub ($c) { $backup_c->get_schedule($c) });
    $protected->put('/backup/schedule' => sub ($c) { $backup_c->update_schedule($c) });
    $protected->get('/backup/s3' => sub ($c) { $backup_c->get_s3_config($c) });
    $protected->put('/backup/s3' => sub ($c) { $backup_c->update_s3_config($c) });
    $protected->post('/backup/upload-s3' => sub ($c) { $backup_c->upload_to_s3($c) });
    $protected->get('/backup' => sub ($c) { $backup_c->list($c) });
    $protected->post('/backup' => sub ($c) { $backup_c->create($c) });
    $protected->post('/backup/restore' => sub ($c) { $backup_c->restore($c) });
    $protected->get('/backup/:id/download' => sub ($c) { $backup_c->download($c) });
    $protected->delete('/backup/:id' => sub ($c) { $backup_c->remove($c) });

    # ============================================
    # Audit log endpoints
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
    # The LLM-backed calls get their own per-user budget (#83).
    my $ai_llm = $protected->under('/ai' => sub ($c) {
        return 1 if $auth_middleware->check_ai_rate_limit($c);
        my $max    = $auth_middleware->ai_rate_limit_max;
        my $window = $auth_middleware->ai_rate_limit_window;
        return _render_rate_limited($c,
            "AI rate limit exceeded: at most $max AI requests per ${window}s",
            $auth_middleware->ai_rate_limit_retry_after($c));
    });
    $ai_llm->post('/query'          => sub ($c) { $ai_c->query($c) });
    $ai_llm->post('/analyze'        => sub ($c) { $ai_c->analyze($c) });
    $ai_llm->post('/explain'        => sub ($c) { $ai_c->explain($c) });
    $protected->get('/ai/suggest'   => sub ($c) { $ai_c->suggest($c) });
    $protected->get('/ai/providers' => sub ($c) { $ai_c->providers($c) });

    # ============================================
    # Clusters endpoint (multi-cluster support)
    # ============================================
    $protected->get('/clusters' => sub ($c) { $clusters_c->list($c) });

    # ============================================
    # WebSocket for live tail
    #
    # MUST hang off $protected, not $api: this is the live log firehose. On
    # $api the handshake skipped check_auth entirely, so an anonymous client
    # got 101 Switching Protocols and every ingested log while GET /api/logs
    # correctly returned 401.
    #
    # Browsers cannot set custom headers on a WebSocket handshake, so the
    # dashboard authenticates with the ambient session cookie — which the
    # handshake DOES send (same origin) and which $protected's check_auth
    # accepts. Programmatic clients still work via the X-API-Key header.
    # The handshake is a GET, so the CSRF gate in $protected is a no-op.
    # ============================================
    $protected->websocket('/logs/stream' => sub ($c) {
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
                        # One typed {"type":"log","data":{...}} frame per log —
                        # see Purl::API::LiveTail for why the shape matters.
                        send_logs($ws, $logs);
                        1;
                    };
                },
            );
        }

        $c->on(message => sub ($c, $msg) { handle_client_message($ws, $msg) });

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

        my $mode = 'direct';
        if ($broadcaster) {
            $mode = ref($broadcaster) =~ /Redis/  ? 'redis'
                  : ref($broadcaster) =~ /Prefork/ ? 'prefork'
                  :                                  'local';
        }
        send_connected($ws, $mode);
    });

    # Unmatched /api/* (any method) is a JSON 404, never the SPA index (#84).
    # Must stay the LAST /api route: Mojolicious matches in definition order.
    $api->any('/*api_path' => { api_path => '' } => sub ($c) {
        $c->render(json => { error => 'Not found' }, status => 404);
    });

    # SPA fallback (non-API paths only — /api/* is caught above)
    app->routes->get('/*catchall' => { catchall => '' } => sub ($c) {
        $c->reply->static('index.html');
    });

    return app;
}

sub run {
    my ($self, %options) = @_;

    # setup_routes() folds env+file config into $config (see there), so it
    # MUST run before we read server.host / server.port / server.workers.
    $self->setup_routes();

    my $server_config = $config->{server} // {};
    my $host    = $options{host} // $server_config->{host} // '0.0.0.0';
    my $port    = $options{port} // $server_config->{port} // 3000;
    my $workers = $options{workers} // $server_config->{workers} // 4;

    app->log->level('info');
    app->log->info("Starting Purl server (prefork) on http://$host:$port with $workers worker(s)");

    return $self->build_prefork(host => $host, port => $port, workers => $workers)->run;
}

# Build (but do not run) the prefork server. Split out from run() so tests
# can inspect the configured server object (workers, listen, type) without
# binding a socket. Wires up the graceful-shutdown cleanup hooks.
sub build_prefork {
    my ($self, %opts) = @_;

    my $host    = $opts{host}    // '0.0.0.0';
    my $port    = $opts{port}    // 3000;
    my $workers = $opts{workers} // 4;

    my $prefork = Mojo::Server::Prefork->new(
        app     => app,
        listen  => ["http://$host:$port"],
        workers => $workers,
    );

    # ------------------------------------------------------------------
    # Graceful shutdown model (PREFORK).
    #
    # We do NOT install our own $SIG{TERM}/$SIG{INT} handlers: the prefork
    # manager owns process signals and its handlers are installed with
    # `local` inside run() (anything we set would be clobbered anyway).
    #
    # Signal semantics of Mojo::Server::Prefork:
    #   SIGQUIT -> graceful: manager sends QUIT to each worker, workers
    #              stop accepting, finish in-flight requests, then exit.
    #   SIGTERM/SIGINT -> immediate: workers are KILLed (drops in-flight).
    # The container is therefore configured (Dockerfile STOPSIGNAL SIGQUIT,
    # k8s preStop `kill -QUIT 1`) to send SIGQUIT so shutdown DRAINS.
    #
    # Cleanup is per-worker because state is per-worker after fork: the
    # ingest buffer and WebSocket list live in EACH worker's memory ->
    # flushed/closed per worker when its IOLoop stops gracefully.
    # Hook: IOLoop singleton `finish` (fires in the draining worker). The
    # manager's prefork `finish` hook only logs the shutdown.
    # ------------------------------------------------------------------
    $prefork->on(finish => sub {
        my ($pf, $graceful) = @_;
        $pf->app->log->info(
            'Manager shutting down (graceful=' . ($graceful ? 1 : 0) . ')');
    });

    Mojo::IOLoop->singleton->on(finish => sub {
        if ($storage && $storage->can('flush')) {
            eval { $storage->flush(); 1 }
                or app->log->error("Buffer flush failed: $@");
        }
        for my $tx (@$websockets) {
            eval { $tx->finish(1001 => 'Server shutting down'); 1 };
        }
    });

    return $prefork;
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

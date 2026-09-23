package Purl::API::Server;
use strict;
use warnings;
use 5.024;

our $VERSION = '1.3.0';

use Mojolicious::Lite -signatures;
use Purl::API::Server::Prefork;
use Time::HiRes qw(time);
use Scalar::Util qw(looks_like_number);
use Purl::Util::ClientIP ();

use Purl::Config;
use Purl::Config::Defaults;
use Purl::API::Middleware::Auth;
use Purl::API::Middleware::NamespaceScope;
use Purl::API::Server::Builders;
use Purl::API::Server::Bootstrap;
use Purl::API::Server::Cron;
use Purl::API::Server::Hooks;
use Purl::API::Server::Shutdown;
use Purl::API::Routes;

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
use Purl::API::Controller::Settings::Notifications;
use Purl::API::Controller::Settings::ApiKeys;
use Purl::API::Controller::Settings::Users;
use Purl::API::Controller::Settings::LDAP;
use Purl::API::Controller::Settings::SSO;
use Purl::API::Controller::Settings::AI;
use Purl::API::Controller::Settings::Redis;
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

# This module is the composition root: it owns the process-wide state below,
# builds the controllers and hands everything to the modules that do the work
#   Purl::API::Server::Builders   storage / notifiers / broadcaster / LDAP / SAML
#   Purl::API::Server::Bootstrap  sessions, initial admin, schema init
#   Purl::API::Server::Cron       recurring jobs + singleton cron leadership
#   Purl::API::Server::Hooks      security headers, CORS, metrics, audit helper
#   Purl::API::Server::Prefork    prefork manager: SIGTERM/SIGINT stop gracefully
#   Purl::API::Server::Shutdown   per-worker exit: flush ingest buffer, close WebSockets
#   Purl::API::Routes(::*)        the route table
#
# PREFORK: all of this runs in the manager before build_prefork->run forks,
# so every value here is COPIED into each worker, not shared between them.

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

# Shared cache for all controllers
my %cache;

# Auth middleware instance
my $auth_middleware;

# LDAP middleware instance
my $ldap_middleware;

# SAML middleware instance
my $saml_middleware;

# Namespace scope middleware instance
my $namespace_scope;

sub create {
    my ($class, %args) = @_;
    $config = $args{config} // {};
    return bless {}, $class;
}

# Read-only view of the effective config hashref handed to controllers
# (%c_args config => ...). Populated by create() and enriched by
# setup_routes() (env+file folding for pipeline/server). Used to assert the
# controller config contract, e.g. config->{pipeline} for the ReDoS guard.
sub effective_config { return $config }

# Dependency seams. Kept as package subs (not inlined) because tests replace
# them — e.g. *Purl::API::Server::_build_storage — to run the app on a mock.
sub _build_storage { return Purl::API::Server::Builders::build_storage($config) }

sub _build_notifiers {
    return Purl::API::Server::Builders::build_notifiers($settings, \%notifiers);
}

sub _build_broadcaster {
    return Purl::API::Server::Builders::build_broadcaster($settings, app->log);
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
    my $trusted_proxies = Purl::Util::ClientIP::parse_proxy_list(
        $settings->get('security', 'trusted_proxies') // ''
    );
    $auth_middleware->trusted_proxies($trusted_proxies);
    my $csrf_enabled = $settings->get('security', 'csrf_enabled');
    $csrf_enabled = 1 unless defined $csrf_enabled;
    $auth_middleware->csrf_enabled($csrf_enabled ? 1 : 0);

    # Initialize LDAP middleware if configured
    $ldap_middleware = Purl::API::Server::Builders::build_ldap_middleware($settings);
    $saml_middleware = Purl::API::Server::Builders::build_saml_middleware($settings);

    # Initialize namespace scope middleware
    $namespace_scope = Purl::API::Middleware::NamespaceScope->new(
        settings => $settings,
    );

    Purl::API::Server::Bootstrap::configure_sessions(app, $settings);
    Purl::API::Server::Bootstrap::ensure_admin_user($settings, $auth_middleware, app->log);
    Purl::API::Server::Bootstrap::warn_weak_passwords($settings, $auth_middleware, app->log);

    # Common controller args
    my %c_args = (storage => $storage, config => $config, cache => \%cache, namespace_scope => $namespace_scope);

    # Prometheus counters on the SHARED counter store (the same Redis-backed
    # store used for rate limiting and login lockout). Reusing it is the whole
    # point: %metrics below is per-worker, so a scrape of a prefork server sees
    # only one worker's slice of the truth.
    $metrics_counters = Purl::Metrics::Counters->new(
        store => $auth_middleware->counter_store,
    );

    my $controllers = _build_controllers(\%c_args);

    Purl::API::Server::Bootstrap::init_schemas($storage, app->log);

    Purl::API::Server::Cron::register_timers(
        log             => app->log,
        settings        => $settings,
        storage         => sub { $storage },
        alert_scheduler => $controllers->{alerts}->scheduler,
    );

    # Static files
    app->static->paths->[0] = '/app/web/public';

    # The coderefs are read per request, so the hooks and gates always use the
    # middleware/counters the LAST setup_routes() call installed.
    Purl::API::Server::Hooks::install(app,
        metrics          => \%metrics,
        auth_middleware  => sub { $auth_middleware },
        metrics_counters => sub { $metrics_counters },
    );

    Purl::API::Routes::register(app,
        controllers     => $controllers,
        auth_middleware => sub { $auth_middleware },
        metrics         => \%metrics,
        websockets      => $websockets,
        broadcaster     => sub { $broadcaster },
    );

    return app;
}

# Instantiate every controller. The rebuild_* callbacks swap the server's
# storage / LDAP / SAML objects after a settings change and push the new
# instance into every controller that holds one.
sub _build_controllers {
    my ($c_args) = @_;
    my %c_args = %$c_args;
    my %ctl;

    $ctl{system} = Purl::API::Controller::System->new(
        %c_args,
        metrics_counters => $metrics_counters,
    );
    $ctl{auth} = Purl::API::Controller::Auth->new(
        %c_args,
        auth_middleware    => $auth_middleware,
        ldap_middleware    => $ldap_middleware,
        saml_middleware    => $saml_middleware,
        settings           => $settings,
    );
    $ctl{sso_status} = Purl::API::Controller::SSOStatus->new(
        %c_args,
        saml_middleware => $saml_middleware,
    );
    $ctl{traces}         = Purl::API::Controller::Traces->new(%c_args);
    $ctl{analytics}      = Purl::API::Controller::Analytics->new(%c_args, notifier_list => \%notifiers);
    $ctl{logs}           = Purl::API::Controller::Logs->new(%c_args, websockets => $websockets, broadcaster => $broadcaster);
    $ctl{stats}          = Purl::API::Controller::Stats->new(%c_args);
    $ctl{patterns}       = Purl::API::Controller::Patterns->new(%c_args);
    $ctl{saved_searches} = Purl::API::Controller::SavedSearches->new(%c_args);
    $ctl{alerts}         = Purl::API::Controller::Alerts->new(%c_args, notifiers => \%notifiers);

    # Settings, one controller per section.
    my %s_args = (%c_args, settings => $settings);
    $ctl{settings} = Purl::API::Controller::Settings->new(
        %s_args,
        rebuild_storage => sub { $storage = _build_storage() },
    );
    $ctl{settings_notifications} = Purl::API::Controller::Settings::Notifications->new(
        %s_args,
        notifiers         => \%notifiers,
        rebuild_notifiers => sub { _build_notifiers() },
    );
    $ctl{settings_api_keys} = Purl::API::Controller::Settings::ApiKeys->new(
        %s_args,
        auth_middleware => $auth_middleware,
    );
    $ctl{settings_users} = Purl::API::Controller::Settings::Users->new(
        %s_args,
        auth_middleware => $auth_middleware,
    );
    $ctl{settings_ldap} = Purl::API::Controller::Settings::LDAP->new(
        %s_args,
        ldap_middleware => $ldap_middleware,
        rebuild_ldap    => sub {
            $ldap_middleware = Purl::API::Server::Builders::build_ldap_middleware($settings);
            $ctl{settings_ldap}->ldap_middleware($ldap_middleware) if $ctl{settings_ldap};
        },
    );
    $ctl{settings_sso} = Purl::API::Controller::Settings::SSO->new(
        %s_args,
        saml_middleware => $saml_middleware,
        rebuild_saml    => sub {
            $saml_middleware = Purl::API::Server::Builders::build_saml_middleware($settings);
            $ctl{settings_sso}->saml_middleware($saml_middleware) if $ctl{settings_sso};
            $ctl{auth}->saml_middleware($saml_middleware)         if $ctl{auth};
            $ctl{sso_status}->saml_middleware($saml_middleware);
        },
    );
    $ctl{settings_ai}    = Purl::API::Controller::Settings::AI->new(%s_args);
    $ctl{settings_redis} = Purl::API::Controller::Settings::Redis->new(%s_args);

    $ctl{config}          = Purl::API::Controller::Config->new(%c_args, main_config => $config);
    $ctl{audit}           = Purl::API::Controller::Audit->new(%c_args);
    $ctl{backup}          = Purl::API::Controller::Backup->new(%c_args, settings => $settings);
    $ctl{otlp}            = Purl::API::Controller::OTLP->new(%c_args);
    $ctl{escompat}        = Purl::API::Controller::ESCompat->new(%c_args);
    $ctl{syslog}          = Purl::API::Controller::Syslog->new(%c_args);
    $ctl{pipeline}        = Purl::API::Controller::Pipeline->new(%c_args);
    $ctl{dashboard}       = Purl::API::Controller::Dashboard->new(%c_args);
    $ctl{k8saudit}        = Purl::API::Controller::K8sAudit->new(%c_args);
    $ctl{k8shealth}       = Purl::API::Controller::K8sHealth->new(%c_args);
    $ctl{alert_templates} = Purl::API::Controller::AlertTemplates->new(%c_args);
    $ctl{ai}              = Purl::API::Controller::AI->new(%c_args, settings => $settings);
    $ctl{clusters}        = Purl::API::Controller::Clusters->new(%c_args);
    $ctl{agents}          = Purl::API::Controller::Agents->new(%c_args);

    return \%ctl;
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

    # How long a draining worker may take before the manager SIGKILLs it
    # (server.graceful_timeout / PURL_GRACEFUL_TIMEOUT). Anything but a
    # positive, finite number falls back to the default: "inf" and "nan" pass
    # looks_like_number, hence the explicit bound.
    my $default_gt = Purl::Config::Defaults::defaults()->{server}{graceful_timeout};
    my $graceful_timeout = $opts{graceful_timeout} // ($config->{server} // {})->{graceful_timeout};
    unless (defined $graceful_timeout && looks_like_number($graceful_timeout)
            && $graceful_timeout > 0 && $graceful_timeout < 9**9**9) {
        app->log->warn("Invalid server.graceful_timeout '$graceful_timeout', using "
            . "${default_gt}s") if defined $graceful_timeout;
        $graceful_timeout = $default_gt;
    }

    my $prefork = Purl::API::Server::Prefork->new(
        app              => app,
        listen           => ["http://$host:$port"],
        workers          => $workers,
        graceful_timeout => $graceful_timeout,
    );

    # ------------------------------------------------------------------
    # Graceful shutdown model (PREFORK), see #90.
    #
    # Manager: SIGQUIT, SIGTERM and SIGINT all stop GRACEFULLY
    # (Purl::API::Server::Prefork): each worker gets QUIT, stops accepting,
    # finishes in-flight requests, then exits. Stock Mojo SIGKILLs the
    # workers on TERM/INT, which dropped every buffered log.
    #
    # Worker: state is per-worker after fork (ingest buffer, WebSocket
    # list), so each worker flushes/closes its own on its own exit, before
    # global destruction -- see Purl::API::Server::Shutdown.
    # ------------------------------------------------------------------
    $prefork->on(finish => sub {
        my ($pf, $graceful) = @_;
        $pf->app->log->info(
            'Manager shutting down (graceful=' . ($graceful ? 1 : 0) . ')');
    });

    Purl::API::Server::Shutdown::install(
        storage    => sub { $storage },
        websockets => $websockets,
        log        => app->log,
        server     => $prefork,
    );

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

This module is the composition root: it owns the process-wide state, builds
the controllers and hands everything to the modules that do the work.

=head2 Server submodules

    Purl::API::Server::Builders   - storage, notifiers, broadcaster, LDAP, SAML
    Purl::API::Server::Bootstrap  - sessions, initial admin, schema init
    Purl::API::Server::Cron       - recurring jobs + singleton cron leadership
    Purl::API::Server::Hooks      - security headers, CORS, metrics, audit helper
    Purl::API::Server::Prefork    - prefork manager; SIGTERM/SIGINT/SIGQUIT all drain
    Purl::API::Server::Shutdown   - per-worker exit: flush the ingest buffer,
                                    close WebSockets (before global destruction)

=head2 Route table

    Purl::API::Routes               - registers the groups below, auth gates
    Purl::API::Routes::System       - health, metrics, CSRF token, login/logout, SSO
    Purl::API::Routes::Logs         - ingest (incl. OTLP), search, traces, stats,
                                      analytics, patterns, saved searches
    Purl::API::Routes::Management   - alerts, config, settings, agents, backups, audit
    Purl::API::Routes::Integrations - ES-compat, syslog, pipelines, dashboards,
                                      k8s, AI (rate-limited), clusters
    Purl::API::Routes::LiveTail     - WebSocket live tail

=head2 Controllers

    Purl::API::Controller::Logs          - Log search/ingest
    Purl::API::Controller::Traces        - Trace correlation
    Purl::API::Controller::System        - Health/metrics
    Purl::API::Controller::Analytics     - Table stats, slow queries
    Purl::API::Controller::Auth          - Login, sessions, CSRF tokens
    Purl::API::Controller::Stats         - Field stats, histograms
    Purl::API::Controller::Patterns      - Log pattern analysis
    Purl::API::Controller::SavedSearches - Saved search CRUD
    Purl::API::Controller::Alerts        - Alert management
    Purl::API::Controller::Config        - Read-only configuration
    Purl::API::Controller::OTLP          - OpenTelemetry OTLP/JSON log ingest

Runtime settings are split by area, one controller each:

    Purl::API::Controller::Settings                - overview, ClickHouse, retention
    Purl::API::Controller::Settings::Notifications - Telegram, Slack, webhook
    Purl::API::Controller::Settings::ApiKeys       - ingest API keys
    Purl::API::Controller::Settings::Users         - users and roles
    Purl::API::Controller::Settings::LDAP          - LDAP
    Purl::API::Controller::Settings::SSO           - SAML SSO
    Purl::API::Controller::Settings::AI            - AI provider
    Purl::API::Controller::Settings::Redis         - Redis / broadcast mode

=cut

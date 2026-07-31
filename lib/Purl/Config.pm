package Purl::Config;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use Fcntl qw(:flock);
use File::Spec;
use Time::HiRes ();

# Config file path
has 'config_file' => (
    is      => 'ro',
    default => sub { $ENV{PURL_CONFIG_FILE} // '/app/config/settings.json' },
);

# In-memory config cache
has '_config' => (
    is      => 'rw',
    default => sub { {} },
);

# Identity of the settings.json revision currently held in _config.
# "" means "nothing loaded yet" and always forces a load.
has '_file_stamp' => (
    is      => 'rw',
    default => sub { '' },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->pretty->canonical },
);

# Default configuration
my $DEFAULTS = {
    server => {
        host    => '0.0.0.0',
        port    => 3000,
        workers => 4,
    },
    security => {
        # Comma-separated CIDRs/IPs allowed to set X-Forwarded-For.
        # Empty means: never trust the header, always use the socket peer.
        trusted_proxies => '',
        csrf_enabled    => 1,
    },
    ingest => {
        # When true, ClickHouse must confirm the write before we return 2xx.
        durable    => 0,
        buffer_max => 10_000,
    },
    pipeline => {
        regex_timeout_ms  => 250,
        regex_max_length  => 512,
    },
    clickhouse => {
        host     => 'localhost',
        port     => 8123,
        database => 'purl',
        user     => 'default',
        password => '',
    },
    retention => {
        days => 30,
    },
    alerts => {
        # How often the server-side alert timer evaluates every alert rule.
        # 0 disables the background evaluation entirely (manual
        # POST /api/alerts/check only).
        check_interval_seconds => 60,
    },
    auth => {
        enabled  => 0,
        api_keys => [],
    },
    license => {
        key               => '',
        public_key        => '',
        api_url           => 'https://purlogs.com',
        verify_on_startup => 1,
        cache_ttl         => 3600,
    },
    ldap => {
        enabled        => 0,
        server         => '',
        port           => 389,
        bind_dn        => '',
        bind_password  => '',
        search_base    => '',
        search_filter  => '({user_attr}={username})',
        tls_enabled    => 0,
        tls_verify     => 'require',
        timeout        => 5,
        mode           => 'ldap',
        user_attr      => 'uid',
        mail_attr      => 'mail',
        group_attr     => 'memberOf',
        base_dn        => '',
    },
    saml => {
        enabled         => 0,
        entity_id       => '',
        idp_entity_id   => '',
        idp_sso_url     => '',
        idp_slo_url     => '',
        idp_cert        => '',
        acs_url         => '',
        name_id_format  => 'emailAddress',
        sign_requests   => 0,
        sp_cert         => '',
        sp_key          => '',
        username_attr   => 'email',
        groups_attr     => 'groups',
        allowed_groups  => '',
        force_authn     => 0,
    },
    backup => {
        schedule_enabled        => 0,
        schedule_interval_hours => 24,
        retention_days          => 30,
        dir                     => '/app/backups',
        s3_enabled              => 0,
        s3_bucket               => '',
        s3_region               => 'us-east-1',
        s3_prefix               => 'purl-backups/',
        s3_access_key           => '',
        s3_secret_key           => '',
        s3_endpoint             => '',
    },
    redis => {
        url  => '',
        mode => 'auto',   # auto | local | redis
    },
    ai => {
        provider        => 'openai',  # openai | anthropic | gemini | ollama
        api_key         => '',
        model           => '',        # empty = use provider default
        base_url        => '',        # for ollama: http://localhost:11434
        enabled         => 1,
        max_log_context => 20,        # max logs to send for analysis
        cache_ttl       => 300,       # cache AI responses (seconds)
    },
    notifications => {
        telegram => {
            enabled   => 0,
            bot_token => '',
            chat_id   => '',
        },
        slack => {
            enabled     => 0,
            webhook_url => '',
            channel     => '',
        },
        webhook => {
            enabled    => 0,
            url        => '',
            auth_token => '',
        },
    },
};

sub BUILD {
    my ($self) = @_;
    $self->load();
}

# ============================================
# Cross-process freshness
# ============================================
#
# The server runs prefork: setup_routes() builds ONE Purl::Config in the
# manager and every worker inherits a private copy through fork(). A worker
# that creates a user mutates its own copy and writes settings.json; the other
# workers keep the pre-fork snapshot forever. That is why a freshly created
# user could not log in — the login request usually landed on a worker that had
# never heard of them.
#
# So the in-memory copy is treated as a cache of the file, not as the truth:
# every read checks whether settings.json changed underneath us and reloads.
# The check is one stat(2); the file is a few kB and read at most once per
# change.
sub _stat_stamp {
    my ($self) = @_;
    # Time::HiRes::stat gives a sub-second mtime. Plain stat(2) truncates to
    # whole seconds, so two saves inside the same second with the same byte
    # count would look identical and the second one would never be picked up.
    my @st = Time::HiRes::stat($self->config_file) or return '';
    # inode : size : mtime — a change to any of them means a new revision.
    return join(':', $st[1], $st[7], $st[9]);
}

sub _reload_if_changed {
    my ($self) = @_;
    return if $self->{_in_reload};

    my $stamp = $self->_stat_stamp;
    return if $stamp eq '' || $stamp eq $self->_file_stamp;

    local $self->{_in_reload} = 1;
    $self->load();
    return;
}

# Every read of the in-memory config goes through the accessor, so hooking it
# is what makes the freshness check impossible to forget in a new call site.
# Writes (and the reload itself) pass straight through.
around '_config' => sub {
    my ($orig, $self, @args) = @_;
    $self->_reload_if_changed unless @args;
    return $self->$orig(@args);
};

# ============================================
# Cross-process mutual exclusion
# ============================================
#
# The atomic write-then-rename in save() closes TORN READS. It does nothing
# about LOST UPDATES, which is the failure operators actually hit:
#
#   worker A: get_section('auth')  -> {users => {admin}}
#   worker B: get_section('auth')  -> {users => {admin}}
#   worker B: adds bob,   save()   -> {admin, bob}
#   worker A: adds alice, save()   -> {admin, alice}   # bob is gone
#
# Both workers believed they held current state — since every read re-checks
# the file, both were RIGHT at the moment they read. The read and the write
# have to be one critical section, which needs a real lock.
#
# The lock is an flock(2) on a sidecar file next to settings.json. It is never
# taken around a plain read: readers are already safe against a partial file
# because writers rename into place.
sub _lock_path {
    my ($self) = @_;
    return $self->config_file . '.lock';
}

# How long _acquire_lock keeps trying, and how long it sleeps between tries.
# The critical sections are a stat, a decode and a rename, so a contended lock
# clears in milliseconds; anything still blocked after a second is not
# contention, it is a wedged holder.
our $LOCK_TIMEOUT  = 1.0;
our $LOCK_RETRY_MS = 10;

# Take the exclusive lock WITHOUT blocking the process indefinitely.
#
# A plain flock(LOCK_EX) parks the whole Mojolicious worker: it is a single
# event loop, so every other in-flight request on that worker — including
# ingest — stops until the lock is released. Nothing bounds that wait.
#
# LOCK_NB plus a bounded retry keeps the failure mode small and known: after
# $LOCK_TIMEOUT we give up and the caller degrades to the SAME unlocked path it
# already takes when the lock file cannot be opened at all.
sub _acquire_lock {
    my ($self, $fh, $path) = @_;

    my $deadline = Time::HiRes::time() + $LOCK_TIMEOUT;
    while (1) {
        return 1 if flock($fh, LOCK_EX | LOCK_NB);

        # Only "somebody else holds it" is worth retrying. A real error
        # (no flock support on this filesystem) will never clear.
        unless ($!{EWOULDBLOCK} || $!{EAGAIN}) {
            warn "Cannot lock $path: $!";
            return 0;
        }

        if (Time::HiRes::time() >= $deadline) {
            warn "Timed out waiting for config lock $path after ${LOCK_TIMEOUT}s; "
                . 'proceeding without it';
            return 0;
        }
        Time::HiRes::sleep($LOCK_RETRY_MS / 1000);
    }
}

# Run $cb holding an exclusive lock, with the in-memory copy refreshed from
# disk FIRST so the callback modifies the newest revision and not our snapshot.
#
# Re-entrant: flock on a second descriptor would block against our own lock, so
# a nested call runs inline instead of deadlocking.
#
# If the lock cannot be taken (read-only directory, exotic filesystem) the
# callback still runs. Degrading to today's behaviour beats refusing to save.
sub _with_lock {
    my ($self, $cb) = @_;

    return $cb->() if $self->{_in_lock};

    my $path = $self->_lock_path;
    my $dir  = File::Spec->catpath((File::Spec->splitpath($path))[0, 1], '');
    if ($dir && !-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir) };
    }

    my $fh;
    unless (open $fh, '>>', $path) {
        warn "Cannot open config lock $path: $!";
        return $cb->();
    }
    unless ($self->_acquire_lock($fh, $path)) {
        close $fh;
        return $cb->();
    }

    local $self->{_in_lock} = 1;

    # Adopt whatever is on disk right now. Anything another worker committed
    # while we waited for the lock is part of the base we are about to modify.
    $self->_reload_if_changed;

    my @result = eval { $cb->() };
    my $err = $@;

    flock($fh, LOCK_UN);
    close $fh;

    die $err if $err;
    return wantarray ? @result : $result[0];
}

# Strip every ENV-provided value out of a section about to be written to disk.
#
# get_section() resolves ENV over file, so the hash a caller just edited also
# carries whatever the environment supplied — including secrets. Writing it
# back does two bad things:
#
#   1. it copies the Kubernetes Secret onto the config PVC in plaintext
#      (PURL_CLICKHOUSE_PASSWORD, PURL_API_KEYS, PURL_LDAP_BIND_PASSWORD,
#      PURL_AI_API_KEY), and that PVC is annotated resource-policy: keep;
#   2. it freezes the env value into the file where ENV still wins on READ, so
#      an edit to that key looks saved and has no effect. That is how revoking
#      an API key could report success while the key kept authenticating.
#
# An ENV-managed key is not ours to write, so it keeps whatever the FILE held
# (nothing, usually) and the caller's copy of the env value is dropped.
sub _without_env_values {
    my ($self, $section, $data) = @_;
    return $data unless ref $data eq 'HASH';

    my $file_section = $self->_config->{$section};
    my %clean = %$data;

    for my $key (keys %clean) {
        next unless $self->is_from_env($section, $key);
        if (ref $file_section eq 'HASH' && exists $file_section->{$key}) {
            $clean{$key} = $file_section->{$key};
        }
        else {
            delete $clean{$key};
        }
    }

    return \%clean;
}

# Read-modify-write a whole section atomically.
#
# $cb receives the CURRENT section (already merged with defaults, already
# reloaded under the lock) and mutates it in place. This is the only safe way
# to edit a section that other workers also edit — the get_section/mutate/
# set_section sequence spelled out by hand has a lost-update window between the
# two calls, which is how a freshly created user could vanish.
#
# $cb also receives a cancel callback: calling it aborts the write entirely and
# update_section returns false. For a read-modify-write that discovers under the
# lock that there is nothing to change (revoking a key that is not there), that
# is the difference between a no-op and rewriting the file for nothing.
sub update_section {
    my ($self, $section, $cb) = @_;

    return $self->_with_lock(sub {
        my $data = $self->get_section($section);

        my $cancelled = 0;
        $cb->($data, sub { $cancelled = 1 });
        return 0 if $cancelled;

        $self->_config->{$section} = $self->_without_env_values($section, $data);
        return $self->save();
    });
}

# Load config from file
sub load {
    my ($self) = @_;

    my $file = $self->config_file;

    # Stamp BEFORE reading: if the file changes while we read it, the stamp we
    # recorded is the older one and the next access reloads again.
    $self->_file_stamp($self->_stat_stamp);

    if (-f $file) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open $file: $!";
            local $/;
            my $json = <$fh>;
            close $fh;

            $self->_config($self->_json->decode($json));
        };
        if ($@) {
            # NEVER blank the in-memory config here. Since workers re-read on
            # every access, a decode failure is far more likely to be a
            # transient torn read than a genuinely corrupt file — and blanking
            # would drop every user, API key and the license, then persist that
            # emptiness the next time anything called save().
            # Clearing the stamp makes the next access retry the read.
            warn "Failed to load config from $file: $@";
            $self->_file_stamp('');
        }
    }

    return $self->_config;
}

# Save config to file
sub save {
    my ($self) = @_;

    my $file = $self->config_file;
    my $dir = File::Spec->catpath((File::Spec->splitpath($file))[0, 1], '');

    # Ensure directory exists
    if ($dir && !-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    eval {
        # Serialize what the caller actually mutated. A freshness reload here
        # would silently discard their unsaved change and write someone else's
        # revision back while still reporting success.
        local $self->{_in_reload} = 1;
        my $payload = $self->_json->encode($self->_config);

        # Write-then-rename, NOT truncate-then-print. Every worker now re-reads
        # this file whenever its stat stamp moves, and truncation moves the
        # stamp instantly — so an in-place write guarantees that any worker
        # touching config in that window reads a partial file. rename(2) is
        # atomic on POSIX: readers see either the old file or the new one.
        my $tmp = "$file.tmp.$$";
        open my $fh, '>:encoding(UTF-8)', $tmp or die "Cannot write $tmp: $!";
        print $fh $payload or do { my $e = $!; close $fh; unlink $tmp; die "Cannot write $tmp: $e" };
        close $fh or do { my $e = $!; unlink $tmp; die "Cannot close $tmp: $e" };
        rename $tmp, $file or do { my $e = $!; unlink $tmp; die "Cannot rename $tmp to $file: $e" };
    };
    if ($@) {
        warn "Failed to save config to $file: $@";
        $self->{_last_save_error} = "$@";
        return 0;
    }

    # We are now the newest revision. Without this the next read would reload
    # what we just wrote and hand back a DIFFERENT hashref, detaching any
    # reference a caller still holds into the old structure.
    $self->_file_stamp($self->_stat_stamp);

    return 1;
}

# ============================================
# "section.key" => ENV var name.
#
# SINGLE SOURCE OF TRUTH. This map used to be copy-pasted into both get() and
# is_from_env(); the two copies had already drifted (server.host, server.port,
# notifications.slack.channel and notifications.webhook.auth_token existed only
# in get(), so is_from_env() wrongly reported those as file-editable). One
# constant, both readers.
# ============================================
my %ENV_MAP = (
    'clickhouse.host'     => 'PURL_CLICKHOUSE_HOST',
    'clickhouse.port'     => 'PURL_CLICKHOUSE_PORT',
    'clickhouse.database' => 'PURL_CLICKHOUSE_DATABASE',
    'clickhouse.user'     => 'PURL_CLICKHOUSE_USER',
    'clickhouse.password' => 'PURL_CLICKHOUSE_PASSWORD',
    'retention.days'      => 'PURL_RETENTION_DAYS',
    'auth.enabled'        => 'PURL_AUTH_ENABLED',
    'auth.api_keys'       => 'PURL_API_KEYS',
    'server.host'         => 'PURL_HOST',
    'server.port'         => 'PURL_PORT',
    'license.key'               => 'PURL_LICENSE_KEY',
    'license.public_key'        => 'PURL_LICENSE_PUBLIC_KEY',
    'license.api_url'           => 'PURL_LICENSE_API_URL',
    'license.verify_on_startup' => 'PURL_LICENSE_VERIFY',
    'license.cache_ttl'         => 'PURL_LICENSE_CACHE_TTL',
    'notifications.telegram.bot_token' => 'PURL_TELEGRAM_BOT_TOKEN',
    'notifications.telegram.chat_id'   => 'PURL_TELEGRAM_CHAT_ID',
    'notifications.slack.webhook_url'  => 'PURL_SLACK_WEBHOOK_URL',
    'notifications.slack.channel'      => 'PURL_SLACK_CHANNEL',
    'notifications.webhook.url'        => 'PURL_ALERT_WEBHOOK_URL',
    'notifications.webhook.auth_token' => 'PURL_ALERT_WEBHOOK_TOKEN',
    'ldap.enabled'       => 'PURL_LDAP_ENABLED',
    'ldap.server'        => 'PURL_LDAP_SERVER',
    'ldap.port'          => 'PURL_LDAP_PORT',
    'ldap.bind_dn'       => 'PURL_LDAP_BIND_DN',
    'ldap.bind_password' => 'PURL_LDAP_BIND_PASSWORD',
    'ldap.search_base'   => 'PURL_LDAP_SEARCH_BASE',
    'ldap.search_filter' => 'PURL_LDAP_SEARCH_FILTER',
    'ldap.tls_enabled'   => 'PURL_LDAP_TLS_ENABLED',
    'ldap.tls_verify'    => 'PURL_LDAP_TLS_VERIFY',
    'ldap.timeout'       => 'PURL_LDAP_TIMEOUT',
    'ldap.mode'          => 'PURL_LDAP_MODE',
    'ldap.user_attr'     => 'PURL_LDAP_USER_ATTR',
    'ldap.mail_attr'     => 'PURL_LDAP_MAIL_ATTR',
    'ldap.group_attr'    => 'PURL_LDAP_GROUP_ATTR',
    'ldap.base_dn'       => 'PURL_LDAP_BASE_DN',
    'saml.enabled'        => 'PURL_SAML_ENABLED',
    'saml.entity_id'      => 'PURL_SAML_ENTITY_ID',
    'saml.idp_entity_id'  => 'PURL_SAML_IDP_ENTITY_ID',
    'saml.idp_sso_url'    => 'PURL_SAML_IDP_SSO_URL',
    'saml.idp_slo_url'    => 'PURL_SAML_IDP_SLO_URL',
    'saml.idp_cert'       => 'PURL_SAML_IDP_CERT',
    'saml.acs_url'        => 'PURL_SAML_ACS_URL',
    'saml.name_id_format' => 'PURL_SAML_NAME_ID_FORMAT',
    'saml.sign_requests'  => 'PURL_SAML_SIGN_REQUESTS',
    'saml.sp_cert'        => 'PURL_SAML_SP_CERT',
    'saml.sp_key'         => 'PURL_SAML_SP_KEY',
    'saml.username_attr'  => 'PURL_SAML_USERNAME_ATTR',
    'saml.groups_attr'    => 'PURL_SAML_GROUPS_ATTR',
    'saml.allowed_groups' => 'PURL_SAML_ALLOWED_GROUPS',
    'saml.force_authn'    => 'PURL_SAML_FORCE_AUTHN',
    'backup.schedule_enabled'        => 'PURL_BACKUP_SCHEDULE_ENABLED',
    'backup.schedule_interval_hours' => 'PURL_BACKUP_SCHEDULE_INTERVAL_HOURS',
    'backup.retention_days'          => 'PURL_BACKUP_RETENTION_DAYS',
    'backup.dir'                     => 'PURL_BACKUP_DIR',
    'backup.s3_enabled'              => 'PURL_BACKUP_S3_ENABLED',
    'backup.s3_bucket'               => 'PURL_BACKUP_S3_BUCKET',
    'backup.s3_region'               => 'PURL_BACKUP_S3_REGION',
    'backup.s3_prefix'               => 'PURL_BACKUP_S3_PREFIX',
    'backup.s3_access_key'           => 'AWS_ACCESS_KEY_ID',
    'backup.s3_secret_key'           => 'AWS_SECRET_ACCESS_KEY',
    'backup.s3_endpoint'             => 'PURL_BACKUP_S3_ENDPOINT',
    'redis.url'           => 'PURL_REDIS_URL',
    'redis.mode'          => 'PURL_BROADCAST_MODE',
    'ai.provider'         => 'PURL_AI_PROVIDER',
    'ai.api_key'          => 'PURL_AI_API_KEY',
    'ai.model'            => 'PURL_AI_MODEL',
    'ai.base_url'         => 'PURL_AI_BASE_URL',
    'server.workers'              => 'PURL_WORKERS',
    'security.trusted_proxies'    => 'PURL_TRUSTED_PROXIES',
    'security.csrf_enabled'       => 'PURL_CSRF_ENABLED',
    'ingest.durable'              => 'PURL_INGEST_DURABLE',
    'ingest.buffer_max'           => 'PURL_INGEST_BUFFER_MAX',
    'pipeline.regex_timeout_ms'   => 'PURL_PIPELINE_REGEX_TIMEOUT_MS',
    'pipeline.regex_max_length'   => 'PURL_PIPELINE_REGEX_MAX_LENGTH',
    'alerts.check_interval_seconds' => 'PURL_ALERT_CHECK_INTERVAL',
);

# Get a config value with priority: ENV > file > default
sub get {
    my ($self, $section, $key) = @_;

    # 1. Check environment variable first
    my $full_key = "$section.$key";
    if (my $env = $ENV_MAP{$full_key}) {
        return $ENV{$env} if exists $ENV{$env} && defined $ENV{$env} && $ENV{$env} ne '';
    }

    # 2. Check file config
    if (exists $self->_config->{$section} && exists $self->_config->{$section}{$key}) {
        return $self->_config->{$section}{$key};
    }

    # 3. Return default
    return $DEFAULTS->{$section}{$key} // undef;
}

# Get nested config value
sub get_nested {
    my ($self, @path) = @_;

    # Build env key
    my $env_key = 'PURL_' . join('_', map { uc($_) } @path);

    # Check env first
    my %env_map = (
        'PURL_NOTIFICATIONS_TELEGRAM_BOT_TOKEN' => 'PURL_TELEGRAM_BOT_TOKEN',
        'PURL_NOTIFICATIONS_TELEGRAM_CHAT_ID'   => 'PURL_TELEGRAM_CHAT_ID',
        'PURL_NOTIFICATIONS_SLACK_WEBHOOK_URL'  => 'PURL_SLACK_WEBHOOK_URL',
        'PURL_NOTIFICATIONS_SLACK_CHANNEL'      => 'PURL_SLACK_CHANNEL',
        'PURL_NOTIFICATIONS_WEBHOOK_URL'        => 'PURL_ALERT_WEBHOOK_URL',
        'PURL_NOTIFICATIONS_WEBHOOK_AUTH_TOKEN' => 'PURL_ALERT_WEBHOOK_TOKEN',
    );

    my $mapped_key = $env_map{$env_key} // $env_key;
    return $ENV{$mapped_key} if exists $ENV{$mapped_key} && defined $ENV{$mapped_key} && $ENV{$mapped_key} ne '';

    # Check file config
    my $val = $self->_config;
    for my $key (@path) {
        return undef unless ref $val eq 'HASH' && exists $val->{$key};
        $val = $val->{$key};
    }
    return $val if defined $val;

    # Check defaults
    $val = $DEFAULTS;
    for my $key (@path) {
        return undef unless ref $val eq 'HASH' && exists $val->{$key};
        $val = $val->{$key};
    }
    return $val;
}

# Set a config value (only in file, not env)
sub set {
    my ($self, $section, $key, $value) = @_;

    # Locked so the reload-mutate-save sequence is one step: without it a
    # concurrent worker's save between our read and our write is discarded.
    return $self->_with_lock(sub {
        $self->_config->{$section} //= {};
        $self->_config->{$section}{$key} = $value;

        return $self->save();
    });
}

# Set nested config value
sub set_nested {
    my ($self, $value, @path) = @_;

    return $self->_with_lock(sub {
        my $config = $self->_config;
        my @keys = @path;
        my $last_key = pop @keys;

        for my $key (@keys) {
            $config->{$key} //= {};
            $config = $config->{$key};
        }

        $config->{$last_key} = $value;

        return $self->save();
    });
}

# Get entire section
sub get_section {
    my ($self, $section) = @_;

    my $result = {};
    my $defaults = $DEFAULTS->{$section} // {};

    for my $key (keys %$defaults) {
        $result->{$key} = $self->get($section, $key);
    }

    # Add any extra keys from file config
    if (my $file_section = $self->_config->{$section}) {
        for my $key (keys %$file_section) {
            $result->{$key} //= $file_section->{$key};
        }
    }

    return $result;
}

# Update entire section.
#
# Wholesale replacement, so it can only ever protect OTHER sections from a
# concurrent writer. When two workers edit the SAME section — adding users is
# the case that bites — use update_section, which re-reads inside the lock.
#
# Every caller builds $data by editing a get_section() result, so it carries the
# same ENV values update_section has to strip — see _without_env_values.
sub set_section {
    my ($self, $section, $data) = @_;

    return $self->_with_lock(sub {
        $self->_config->{$section} = $self->_without_env_values($section, $data);
        return $self->save();
    });
}

# Get all config (merged)
sub get_all {
    my ($self) = @_;

    my $result = {};

    for my $section (keys %$DEFAULTS) {
        $result->{$section} = $self->get_section($section);
    }

    return $result;
}

# Is authentication required on this instance?
#
# ENV > file > default, resolved in ONE place. The auth gate
# (Middleware::Auth::check_auth), the startup weak-password warning and the
# `auth_required` flag /auth/me hands the login UI all read this, and they must
# never disagree — a UI that guesses instead ends up showing a login form on an
# instance that has no credentials to give.
sub auth_enabled {
    my ($self) = @_;
    return $self->get('auth', 'enabled') ? 1 : 0;
}

# Check if value is from env (read-only)
sub is_from_env {
    my ($self, $section, $key) = @_;

    my $full_key = "$section.$key";
    if (my $env = $ENV_MAP{$full_key}) {
        return exists $ENV{$env} && defined $ENV{$env} && $ENV{$env} ne '';
    }

    return 0;
}

# Every key of $section that %ENV_MAP can manage, whether or not the variable
# is currently set.
#
# The read side had the same twin-site defect as the write side: get_ldap
# reported from_env for three of its fourteen mappable keys, get_sso for eight
# of fifteen, so the UI happily left a field editable that the environment
# owned. Building those responses from this list instead of a hand-kept qw()
# means a new entry in %ENV_MAP shows up in the UI the day it is added.
sub env_managed_keys {
    my ($self, $section) = @_;

    my $prefix = "$section.";
    # Sorted into a list first: `return sort ...` is undefined in scalar
    # context, so a caller writing `my $n = env_managed_keys(...)` would get
    # something arbitrary rather than a count or an error.
    my @keys = sort map { substr($_, length $prefix) }
               grep { index($_, $prefix) == 0 } keys %ENV_MAP;
    return @keys;
}

# Which of a caller's proposed changes does the environment own?
#
# ENV wins on every read, so a key with a live ENV value cannot be changed
# through the API: set_section strips it before writing, and set() writes a
# value that get() will never return. Either way the edit does nothing — and
# answering such a request with 200 is the bug this exists to stop. It has now
# been shipped five times over (backups, alert filters, auth middleware, the
# CronJob, and the API-key pair), every time because a fix was applied to the
# endpoint in the report and not to its siblings.
#
# So the decision is made HERE, from %ENV_MAP, for any section and any key. A
# new ENV-managed key is covered by every caller the moment it is added to the
# map; there is no per-endpoint list to forget.
#
# A submitted value EQUAL to the effective one is not a change and is not
# reported: a UI that GETs a config and PUTs the whole form back must keep
# working, and reporting success for a no-op is honest.
#
# $changes is the caller's proposed values keyed by config key (nested keys use
# the dotted form %ENV_MAP uses, e.g. 'telegram.bot_token'). Returns the
# blocked keys, sorted.
sub env_shadowed_keys {
    my ($self, $section, $changes) = @_;
    return () unless ref $changes eq 'HASH';

    my @shadowed;
    for my $key (sort keys %$changes) {
        next unless $self->is_from_env($section, $key);
        next if _same_scalar($self->get($section, $key), $changes->{$key});
        push @shadowed, $key;
    }

    return @shadowed;
}

# ENV values are always strings, so the comparison is a string comparison.
# Blessed scalars (Mojo::JSON booleans) stringify to 1/0, which is what an ENV
# flag holds. Containers can never equal an ENV string.
sub _same_scalar {
    my ($current, $proposed) = @_;

    return 1 if !defined $current && !defined $proposed;
    return 0 if !defined $current || !defined $proposed;
    return 0 if ref $proposed eq 'HASH' || ref $proposed eq 'ARRAY' || ref $proposed eq 'CODE';

    return "$current" eq "$proposed";
}

# ============================================
# User role management (RBAC)
# ============================================

my %VALID_ROLES = map { $_ => 1 } qw(admin operator viewer);

sub get_user_role {
    my ($self, $username) = @_;
    return 'viewer' unless defined $username && $username ne '';
    my $roles = $self->_config->{auth}{roles} // {};
    return $roles->{$username} // 'viewer';
}

sub set_user_role {
    my ($self, $username, $role) = @_;
    $role //= 'viewer';
    $role = 'viewer' unless exists $VALID_ROLES{$role};
    return $self->_with_lock(sub {
        $self->_config->{auth} //= {};
        $self->_config->{auth}{roles} //= {};
        $self->_config->{auth}{roles}{$username} = $role;
        return $self->save();
    });
}

sub ensure_user_roles {
    my ($self) = @_;
    return $self->_with_lock(sub {
        my $users = $self->_config->{auth}{users} // {};
        my $roles = $self->_config->{auth}{roles} // {};
        my $changed = 0;
        my @usernames = sort keys %$users;
        for my $i (0 .. $#usernames) {
            my $u = $usernames[$i];
            unless (exists $roles->{$u}) {
                $roles->{$u} = ($i == 0 || $u eq 'admin') ? 'admin' : 'viewer';
                $changed = 1;
            }
        }
        if ($changed) {
            $self->_config->{auth}{roles} = $roles;
            $self->save();
        }
        return $roles;
    });
}

1;

__END__

=head1 NAME

Purl::Config - Configuration management with ENV > File > Default priority

=head1 SYNOPSIS

    use Purl::Config;

    my $config = Purl::Config->new();

    # Get value (checks ENV, then file, then default)
    my $host = $config->get('clickhouse', 'host');

    # Set value (saves to file)
    $config->set('clickhouse', 'host', 'new-host');

    # Check if from ENV (read-only)
    if ($config->is_from_env('clickhouse', 'host')) {
        # Cannot modify - set via environment
    }

=head1 CONFIGURATION PRIORITY

1. Environment Variables (highest priority, read-only)
2. Config File (/app/config/settings.json)
3. Default Values (lowest priority)

=cut

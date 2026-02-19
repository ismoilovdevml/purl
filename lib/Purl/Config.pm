package Purl::Config;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use File::Spec;

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

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->pretty->canonical },
);

# Default configuration
my $DEFAULTS = {
    server => {
        host => '0.0.0.0',
        port => 3000,
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

# Load config from file
sub load {
    my ($self) = @_;

    my $file = $self->config_file;

    if (-f $file) {
        eval {
            open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open $file: $!";
            local $/;
            my $json = <$fh>;
            close $fh;

            $self->_config($self->_json->decode($json));
        };
        if ($@) {
            warn "Failed to load config from $file: $@";
            $self->_config({});
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
        open my $fh, '>:encoding(UTF-8)', $file or die "Cannot write $file: $!";
        print $fh $self->_json->encode($self->_config);
        close $fh;
    };
    if ($@) {
        warn "Failed to save config to $file: $@";
        return 0;
    }

    return 1;
}

# Get a config value with priority: ENV > file > default
sub get {
    my ($self, $section, $key) = @_;

    # 1. Check environment variable first
    my $env_key = 'PURL_' . uc($section) . '_' . uc($key);
    $env_key =~ s/CLICKHOUSE/CLICKHOUSE/;  # Keep as-is

    # Special env mappings
    my %env_map = (
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
    );

    my $full_key = "$section.$key";
    if (my $env = $env_map{$full_key}) {
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

    $self->_config->{$section} //= {};
    $self->_config->{$section}{$key} = $value;

    return $self->save();
}

# Set nested config value
sub set_nested {
    my ($self, $value, @path) = @_;

    my $config = $self->_config;
    my $last_key = pop @path;

    for my $key (@path) {
        $config->{$key} //= {};
        $config = $config->{$key};
    }

    $config->{$last_key} = $value;

    return $self->save();
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

# Update entire section
sub set_section {
    my ($self, $section, $data) = @_;

    $self->_config->{$section} = $data;
    return $self->save();
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

# Check if value is from env (read-only)
sub is_from_env {
    my ($self, $section, $key) = @_;

    my %env_map = (
        'clickhouse.host'     => 'PURL_CLICKHOUSE_HOST',
        'clickhouse.port'     => 'PURL_CLICKHOUSE_PORT',
        'clickhouse.database' => 'PURL_CLICKHOUSE_DATABASE',
        'clickhouse.user'     => 'PURL_CLICKHOUSE_USER',
        'clickhouse.password' => 'PURL_CLICKHOUSE_PASSWORD',
        'retention.days'      => 'PURL_RETENTION_DAYS',
        'auth.enabled'        => 'PURL_AUTH_ENABLED',
        'auth.api_keys'       => 'PURL_API_KEYS',
        'license.key'               => 'PURL_LICENSE_KEY',
        'license.public_key'        => 'PURL_LICENSE_PUBLIC_KEY',
        'license.api_url'           => 'PURL_LICENSE_API_URL',
        'license.verify_on_startup' => 'PURL_LICENSE_VERIFY',
        'license.cache_ttl'         => 'PURL_LICENSE_CACHE_TTL',
        'notifications.telegram.bot_token' => 'PURL_TELEGRAM_BOT_TOKEN',
        'notifications.telegram.chat_id'   => 'PURL_TELEGRAM_CHAT_ID',
        'notifications.slack.webhook_url'  => 'PURL_SLACK_WEBHOOK_URL',
        'notifications.webhook.url'        => 'PURL_ALERT_WEBHOOK_URL',
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
    );

    my $full_key = "$section.$key";
    if (my $env = $env_map{$full_key}) {
        return exists $ENV{$env} && defined $ENV{$env} && $ENV{$env} ne '';
    }

    return 0;
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
    $self->_config->{auth} //= {};
    $self->_config->{auth}{roles} //= {};
    $self->_config->{auth}{roles}{$username} = $role;
    return $self->save();
}

sub ensure_user_roles {
    my ($self) = @_;
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

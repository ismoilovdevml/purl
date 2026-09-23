package Purl::Config::Defaults;
use strict;
use warnings;
use 5.024;

# The built-in defaults: the lowest layer of Purl::Config's
# ENV > settings.json > default resolution. One shared hashref — callers read
# it, nobody writes it.

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
            # Forum topic id. Empty = the group's General topic.
            thread_id => '',
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

sub defaults { return $DEFAULTS }

1;

__END__

=head1 NAME

Purl::Config::Defaults - built-in default values for Purl::Config (the lowest
precedence layer, below ENV and settings.json).

=cut

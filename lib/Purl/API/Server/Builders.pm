package Purl::API::Server::Builders;
use strict;
use warnings;
use 5.024;

use Purl::Storage::ClickHouse;
use Purl::Alert::Telegram;
use Purl::Alert::Slack;
use Purl::Alert::Webhook;
use Purl::API::Middleware::LDAP;
use Purl::API::Middleware::SAML;
use Purl::Broadcast::Prefork;

# Construction of the server's runtime dependencies from config
# (ENV > settings.json > defaults). Stateless: this module keeps nothing, so
# Purl::API::Server decides what is kept and where — which matters because
# everything built before fork is copied per worker.

sub build_storage {
    my ($config) = @_;
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
        max_query_memory => _max_query_memory($ch_config),
        retention_days => $retention_days,
    );
}

# Per-query memory cap in bytes: ENV > settings.json > 256 MiB. 0 is valid (no
# cap, the server profile decides); anything that is not a whole number would
# be sent to ClickHouse as-is and fail every query, so it falls back loudly.
my $DEFAULT_MAX_QUERY_MEMORY = 268_435_456;

sub _max_query_memory {
    my ($ch_config) = @_;
    my $v = $ENV{PURL_CLICKHOUSE_MAX_QUERY_MEMORY} // $ch_config->{max_query_memory};
    return $DEFAULT_MAX_QUERY_MEMORY unless defined $v && length $v;
    return $v + 0 if $v =~ /\A\d+\z/;
    warn "PURL_CLICKHOUSE_MAX_QUERY_MEMORY '$v' is not a whole number of bytes; "
       . "using $DEFAULT_MAX_QUERY_MEMORY (256 MiB)\n";
    return $DEFAULT_MAX_QUERY_MEMORY;
}

# (Re)fill $into with the configured notifier channels and return it. Filled
# IN PLACE because the controllers hold a reference to that very hash, so a
# rebuild after a settings change is seen by every one of them.
sub build_notifiers {
    my ($settings, $into) = @_;
    my $notifiers = $into // {};
    %$notifiers = ();

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
        $notifiers->{telegram} = Purl::Alert::Telegram->new(
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
        $notifiers->{slack} = Purl::Alert::Slack->new(
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
        $notifiers->{webhook} = Purl::Alert::Webhook->new(
            name       => 'webhook',
            url        => $webhook_url,
            auth_token => $webhook_token,
        );
    }

    return $notifiers;
}

sub build_broadcaster {
    my ($settings, $log) = @_;
    my $redis_url = $ENV{PURL_REDIS_URL}
        // ($settings ? $settings->get('redis', 'url') : '');
    my $mode = $ENV{PURL_BROADCAST_MODE}
        // ($settings ? $settings->get('redis', 'mode') : 'auto');

    # Explicit local mode: no Redis, one container. Still Prefork rather than
    # Broadcast::Local — "local" means "this container", and this container is
    # 4 forked workers, not one process (#64).
    if ($mode eq 'local') {
        $log->info("Broadcast: local mode (cross-worker spool, no Redis)");
        return Purl::Broadcast::Prefork->new();
    }

    # Try Redis if URL is configured and mode is auto or redis
    if ($redis_url && $redis_url ne '') {
        my $redis_broadcaster;
        eval {
            require Purl::Broadcast::Redis;
            $redis_broadcaster = Purl::Broadcast::Redis->new(redis_url => $redis_url);
            if ($redis_broadcaster->is_connected) {
                $log->info("Broadcast: Redis mode ($redis_url)");
            } else {
                $log->warn("Broadcast: Redis configured but not connected, falling back to local");
                $redis_broadcaster = undef;
            }
        };
        if ($@) {
            $log->warn("Broadcast: Redis init failed ($@), falling back to local");
        }
        return $redis_broadcaster if $redis_broadcaster;

        # If mode is explicitly redis but failed, still warn
        if ($mode eq 'redis') {
            $log->warn("Broadcast: Redis mode requested but unavailable, using local fallback");
        }
    }

    # Default: cross-worker spool. Reaches every prefork worker in THIS
    # container; multi-replica deployments need PURL_REDIS_URL.
    $log->info("Broadcast: local mode (cross-worker spool, no Redis configured)");
    return Purl::Broadcast::Prefork->new();
}

sub build_ldap_middleware {
    my ($settings) = @_;
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

sub build_saml_middleware {
    my ($settings) = @_;
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

1;

__END__

=head1 NAME

Purl::API::Server::Builders - build the server's storage, notifier channels,
live-tail broadcaster and LDAP/SAML middleware from configuration

=cut

package Purl::Config::EnvMap;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
our @EXPORT_OK = qw(
    env_var_for env_mapped_keys is_write_only manages_below is_blank same_scalar
);

# Which config keys the environment manages, which keys the API never
# discloses, and the value comparisons both depend on. Plain functions over
# lexical tables (no object state), shared by Purl::Config and its roles.

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
    'notifications.telegram.bot_token' => 'PURL_TELEGRAM_BOT_TOKEN',
    'notifications.telegram.chat_id'   => 'PURL_TELEGRAM_CHAT_ID',
    'notifications.telegram.thread_id' => 'PURL_TELEGRAM_THREAD_ID',
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
    # LLM calls (/api/ai/{query,analyze,explain}) per user per 60s; 0 = off.
    'ai.rate_limit'       => 'PURL_AI_RATE_LIMIT',
    'server.workers'              => 'PURL_WORKERS',
    'security.trusted_proxies'    => 'PURL_TRUSTED_PROXIES',
    'security.csrf_enabled'       => 'PURL_CSRF_ENABLED',
    'ingest.durable'              => 'PURL_INGEST_DURABLE',
    'ingest.buffer_max'           => 'PURL_INGEST_BUFFER_MAX',
    'pipeline.regex_timeout_ms'   => 'PURL_PIPELINE_REGEX_TIMEOUT_MS',
    'pipeline.regex_max_length'   => 'PURL_PIPELINE_REGEX_MAX_LENGTH',
    'alerts.check_interval_seconds' => 'PURL_ALERT_CHECK_INTERVAL',
);

# Keys the API NEVER hands back. Their GET reports a 0/1 "is it set" flag
# (password_set, bot_token, has_credentials) and nothing else, so the input is
# empty on every page load and comes back empty unless the admin retyped it.
#
# An empty submission for one of these therefore means "I did not retype it",
# not "clear it" — the admin was never shown a value to preserve, so there is
# no way for them to express "keep it" other than by leaving it alone.
#
# Deliberately NOT the masked keys (ldap.bind_password, saml.sp_key,
# ai.api_key): their GET returns '********', so that UI CAN distinguish
# "unchanged" (send the mask back, handled by reject_env_managed's
# unchanged_marker) from "clear it" (send empty), and empty must keep clearing
# them.
#
# One list, consulted by every guard and every writer: the four call sites that
# needed this — notifications, clickhouse and both backup endpoints — is exactly
# the shape that gets fixed at one site and forgotten at the other three.
my %WRITE_ONLY = map { $_ => 1 } qw(
    clickhouse.password
    notifications.telegram.bot_token
    notifications.telegram.chat_id
    notifications.slack.webhook_url
    notifications.webhook.url
    notifications.webhook.auth_token
    backup.s3_access_key
    backup.s3_secret_key
);

# A plain sub, not a method: env_shadowed_keys is deliberately borrowable by a
# test double (t/controller/redis_settings.t calls it as a function on its own
# mock, so the mock cannot disagree with production about which keys ENV owns).
# Reaching this through $self would break that the moment it is used.
sub is_write_only {
    my ($section, $key) = @_;
    return $WRITE_ONLY{"$section.$key"} ? 1 : 0;
}

# Does %ENV_MAP manage anything BELOW this key? True only for the nested
# notification channels, and it is what keeps the recursive walk in
# _writable_values off unrelated nested structures (auth.users, auth.roles).
sub manages_below {
    my ($section, $path) = @_;
    my $prefix = "$section.$path.";
    return scalar grep { index($_, $prefix) == 0 } keys %ENV_MAP;
}

# "Not filled in": undef or the empty string. A 0 is a value.
sub is_blank {
    my ($value) = @_;
    return 1 unless defined $value;
    return 0 if ref $value;
    return $value eq '' ? 1 : 0;
}

# ENV values are always strings, so the comparison is a string comparison.
# Blessed scalars (Mojo::JSON booleans) stringify to 1/0, which is what an ENV
# flag holds. Containers can never equal an ENV string.
#
# EXCEPT for booleans, which the two sides spell differently and always have:
# the environment carries PURL_BACKUP_SCHEDULE_ENABLED=true while a JSON body
# carries 1 (Mojo::JSON::true stringifies to 1) and the API hands out 0/1. Read
# as strings, "true" ne "1", so a GET->PUT round-trip that changed NOTHING was
# reported as an attempted edit and 409'd — for backup.schedule_enabled,
# ldap.tls_enabled and saml.sign_requests alike. Normalise both sides first;
# only when BOTH read as booleans, so 'auto' vs 'local' is untouched.
my %BOOL_TEXT = (
    '1' => 1, 'true'  => 1, 'yes' => 1, 'on'  => 1,
    '0' => 0, 'false' => 0, 'no'  => 0, 'off' => 0,
);

sub bool_text {
    my ($value) = @_;
    return undef unless defined $value;
    my $text = lc "$value";
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    return $BOOL_TEXT{$text};
}

sub same_scalar {
    my ($current, $proposed) = @_;

    return 1 if !defined $current && !defined $proposed;
    return 0 if !defined $current || !defined $proposed;
    return 0 if ref $proposed eq 'HASH' || ref $proposed eq 'ARRAY' || ref $proposed eq 'CODE';

    my $current_bool  = bool_text($current);
    my $proposed_bool = bool_text($proposed);
    if (defined $current_bool && defined $proposed_bool) {
        return $current_bool == $proposed_bool ? 1 : 0;
    }

    return "$current" eq "$proposed";
}

# The ENV variable that manages "section.key", or undef.
sub env_var_for {
    my ($full_key) = @_;
    return $ENV_MAP{$full_key};
}

# Every "section.key" the environment can manage (unordered).
sub env_mapped_keys { return keys %ENV_MAP }

1;

__END__

=head1 NAME

Purl::Config::EnvMap - the "section.key" => ENV variable map, the write-only
key list and the value comparisons Purl::Config's ENV rules are built on.

=cut

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json decode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

use PurlTest::Mock qw(mock_ctx mock_storage);

use Purl::Config;
use Purl::API::Controller::Settings;
use Purl::API::Controller::Backup;

# ============================================
# REGRESSION (#53): no settings endpoint may report success for an edit the
# environment owns.
#
# ENV beats file on every read (Purl::Config::get), so while PURL_X is set an
# API write to that key can only do one of two useless things: get stripped
# before it reaches disk (set_section), or land on disk where get() will never
# look at it (set). Either way the value the caller asked for is NOT in effect
# afterwards, and answering 200 tells the UI a change happened that did not.
#
# #45 fixed exactly two endpoints (generate_api_key / revoke_api_key) with a
# hardcoded PURL_API_KEYS check. This file exists because that is the fifth
# time the same fix landed on one site and not its siblings (#34 backups, #43
# alert filters, #37 auth middleware, #49 CronJob, #53 here). So what is pinned
# below is not a list of endpoints — it is that the refusal is derived from
# %ENV_MAP, for EVERY mappable key, including the ones no hand-written check
# ever mentioned.
# ============================================

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

sub fresh_settings {
    unlink $file;
    local $ENV{PURL_CONFIG_FILE} = $file;
    return Purl::Config->new(config_file => $file);
}

sub settings_ctrl {
    my ($settings) = @_;
    return Purl::API::Controller::Settings->new(
        storage  => mock_storage(),
        settings => $settings,
    );
}

sub backup_ctrl {
    my ($settings) = @_;
    return Purl::API::Controller::Backup->new(
        storage  => mock_storage(),
        settings => $settings,
    );
}

# What the API surface looks like: endpoint, the section it writes, an ENV var
# that owns one of its keys, and a body that tries to change that key.
#
# Every env var chosen here is one that NO hand-written check in the codebase
# ever tested for. PURL_CLICKHOUSE_HOST was covered; PURL_LDAP_SEARCH_FILTER,
# PURL_SAML_NAME_ID_FORMAT, PURL_AI_MODEL, PURL_BROADCAST_MODE,
# PURL_TELEGRAM_CHAT_ID, PURL_BACKUP_RETENTION_DAYS and PURL_BACKUP_S3_REGION
# were not — each of those used to answer 200 and change nothing.
my @CASES = (
    {
        name     => 'update_clickhouse',
        env      => { PURL_CLICKHOUSE_HOST => 'env-clickhouse' },
        body     => { host => 'typed-by-admin' },
        blocked  => ['host'],
        call     => sub { $_[0]->update_clickhouse($_[1]) },
    },
    {
        name     => 'update_ldap (key no hardcoded check knew about)',
        env      => { PURL_LDAP_SEARCH_FILTER => '(uid=%s)' },
        body     => { search_filter => '(sAMAccountName=%s)' },
        blocked  => ['search_filter'],
        call     => sub { $_[0]->update_ldap($_[1]) },
    },
    {
        name     => 'update_sso (key no hardcoded check knew about)',
        env      => { PURL_SAML_NAME_ID_FORMAT => 'persistent' },
        body     => { name_id_format => 'emailAddress' },
        blocked  => ['name_id_format'],
        call     => sub { $_[0]->update_sso($_[1]) },
    },
    {
        name     => 'update_ai (key that used to be silently skipped)',
        env      => { PURL_AI_MODEL => 'gpt-4o-mini' },
        body     => { model => 'claude-opus' },
        blocked  => ['model'],
        call     => sub { $_[0]->update_ai($_[1]) },
    },
    {
        name     => 'update_redis (key that used to be silently skipped)',
        env      => { PURL_BROADCAST_MODE => 'redis' },
        body     => { mode => 'local' },
        blocked  => ['mode'],
        call     => sub { $_[0]->update_redis($_[1]) },
    },
    {
        name     => 'update_retention',
        env      => { PURL_RETENTION_DAYS => '30' },
        body     => { days => 7 },
        blocked  => ['days'],
        call     => sub { $_[0]->update_retention($_[1]) },
    },
);

for my $case (@CASES) {
    subtest "$case->{name} refuses an env-owned edit with 409" => sub {
        my %env = %{ $case->{env} };
        local @ENV{ keys %env } = values %env;

        my $settings = fresh_settings();
        my $ctrl     = settings_ctrl($settings);
        my $c        = mock_ctx(body => encode_json($case->{body}));

        $case->{call}->($ctrl, $c);
        my $r = $c->rendered;

        is $r->{status}, 409,
            'conflict — the request is fine, the value belongs to the environment';
        is_deeply $r->{json}{from_env}, $case->{blocked},
            'names exactly the keys that are not ours to change';
        ok !exists $r->{json}{status},
            'and does NOT report a successful save';
    };
}

subtest 'update_notifications refuses PURL_TELEGRAM_CHAT_ID' => sub {
    # The check this replaces only looked at PURL_TELEGRAM_BOT_TOKEN, so an
    # edit to a chat_id pinned by the environment reported 'ok' forever.
    #
    # '-100111' is a value the admin TYPED. The empty string the form posts for
    # a chat_id it was never shown is a different thing entirely and must NOT
    # 409 — see the subtest right below, and t/settings_env_write_paths.t.
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, chat_id => '-100111' }),
        params => { type => 'telegram' },
    );

    $ctrl->update_notifications($c);
    my $r = $c->rendered;

    is $r->{status}, 409, 'conflict on the env-owned chat_id';
    is_deeply $r->{json}{from_env}, ['telegram.chat_id'], 'named by its nested key';
};

subtest 'update_notifications accepts the body the real UI sends' => sub {
    # What the browser actually posts: get_all reports bot_token/chat_id as 0/1
    # "is it set" flags and never the value, so NotificationSettings keeps both
    # inputs at '' until the admin types. Pinning only the typed value above is
    # how this endpoint shipped 409ing every save an operator could make.
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, bot_token => '', chat_id => '' }),
        params => { type => 'telegram' },
    );

    $ctrl->update_notifications($c);
    my $r = $c->rendered;

    is $r->{json}{status}, 'ok', 'the untouched-secret body saves'
        or diag explain $r;
};

subtest 'update_schedule refuses PURL_BACKUP_RETENTION_DAYS' => sub {
    # The old guard was a single check on PURL_BACKUP_SCHEDULE_ENABLED, so
    # every other backup key was writable-and-ignored.
    local $ENV{PURL_BACKUP_RETENTION_DAYS} = '90';
    delete local $ENV{PURL_BACKUP_SCHEDULE_ENABLED};

    my $settings = fresh_settings();
    my $ctrl     = backup_ctrl($settings);
    my $c        = mock_ctx(body => encode_json({ retention_days => 7 }));

    $ctrl->update_schedule($c);
    my $r = $c->rendered;

    is $r->{status}, 409, 'conflict on the env-owned retention';
    is_deeply $r->{json}{from_env}, ['retention_days'], 'named';
    is $settings->get('backup', 'retention_days'), '90', 'env value still in effect';
};

subtest 'update_s3_config refuses PURL_BACKUP_S3_REGION' => sub {
    local $ENV{PURL_BACKUP_S3_REGION} = 'eu-central-1';
    delete local $ENV{PURL_BACKUP_S3_ENABLED};

    my $settings = fresh_settings();
    my $ctrl     = backup_ctrl($settings);
    my $c        = mock_ctx(body => encode_json({ s3_region => 'us-east-1' }));

    $ctrl->update_s3_config($c);
    my $r = $c->rendered;

    is $r->{status}, 409, 'conflict on the env-owned region';
    is_deeply $r->{json}{from_env}, ['s3_region'], 'named';
};

# ============================================
# The property that makes this fix different from the four before it: the
# refusal is not driven by any list written in a controller. Walk EVERY key
# %ENV_MAP can manage for a section and confirm the endpoint refuses it.
#
# A new ENV-managed key added to %ENV_MAP is covered by this the moment it is
# added — which is precisely what did not happen the previous five times.
# ============================================
subtest 'EVERY mappable key of a section is refused, not a curated subset' => sub {
    my %endpoint = (
        ldap  => sub { $_[0]->update_ldap($_[1]) },
        saml  => sub { $_[0]->update_sso($_[1]) },
        ai    => sub { $_[0]->update_ai($_[1]) },
        redis => sub { $_[0]->update_redis($_[1]) },
    );

    my $probe = Purl::Config->new(config_file => $file);

    for my $section (sort keys %endpoint) {
        my @keys = $probe->env_managed_keys($section);
        cmp_ok scalar(@keys), '>', 1, "$section has more than one mappable key";

        for my $key (@keys) {
            my $env_var = _env_var_for($section, $key);

            local $ENV{$env_var} = 'environment-value';
            my $settings = fresh_settings();
            my $ctrl     = settings_ctrl($settings);

            # 'different-value' is never equal to the env value, so this is a
            # real attempted change for every key, whatever its type.
            my $c = mock_ctx(body => encode_json({ $key => 'different-value' }));
            $endpoint{$section}->($ctrl, $c);

            my $r = $c->rendered;
            is $r->{status}, 409, "$section.$key ($env_var) is refused"
                or diag explain $r;
        }
    }
};

# Recover the ENV var name for a mapped key without duplicating %ENV_MAP here:
# set candidate names and ask is_from_env which one it reacts to. A copy of the
# map in this file would be the very thing that keeps drifting.
sub _env_var_for {
    my ($section, $key) = @_;

    my $cfg = Purl::Config->new(config_file => $file);
    for my $candidate (_candidate_env_names($section, $key)) {
        local $ENV{$candidate} = 'x';
        return $candidate if $cfg->is_from_env($section, $key);
    }

    BAIL_OUT("cannot determine ENV var for $section.$key — extend _candidate_env_names");
}

sub _candidate_env_names {
    my ($section, $key) = @_;
    my $KEY = uc $key;
    my $SEC = uc $section;
    return (
        "PURL_${SEC}_${KEY}",
        "PURL_${KEY}",
        "AWS_${KEY}",
        'PURL_BROADCAST_MODE',       # redis.mode
        'PURL_AI_' . $KEY,
        'PURL_ALERT_' . $KEY,
    );
}

subtest 'a no-op resubmit of the env value is accepted, not 409' => sub {
    # The settings UI GETs a config and PUTs the whole form back. The env-owned
    # field comes back carrying the value the GET handed out; nothing changes,
    # so refusing it would make the page permanently unsaveable while telling
    # the admin nothing useful.
    local $ENV{PURL_LDAP_SEARCH_FILTER} = '(uid=%s)';

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c = mock_ctx(body => encode_json({
        search_filter => '(uid=%s)',      # unchanged
        search_base   => 'dc=purl,dc=io', # the actual edit
    }));

    $ctrl->update_ldap($c);
    my $r = $c->rendered;

    is $r->{json}{status}, 'ok', 'accepted';
    is $settings->get_section('ldap')->{search_base}, 'dc=purl,dc=io',
        'the file-owned key really was saved';
};

subtest 'a masked secret sent back unchanged is not an attempted edit' => sub {
    # get_ldap hands the UI '********' for bind_password. Sending it back means
    # "I did not retype it", which must not collide with the env guard.
    local $ENV{PURL_LDAP_BIND_PASSWORD} = 'env-secret';

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c = mock_ctx(body => encode_json({
        bind_password => '********',
        search_base   => 'dc=purl,dc=io',
    }));

    $ctrl->update_ldap($c);
    my $r = $c->rendered;

    is $r->{json}{status}, 'ok', 'the mask is not treated as a change';

    my $on_disk = decode_json(do { open my $fh, '<', $file or die $!; local $/; <$fh> });
    ok !exists $on_disk->{ldap}{bind_password},
        'and the environment secret was not copied into settings.json';
};

subtest 'retyping the masked secret to something else IS refused' => sub {
    local $ENV{PURL_LDAP_BIND_PASSWORD} = 'env-secret';

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c = mock_ctx(body => encode_json({ bind_password => 'admin-typed-this' }));

    $ctrl->update_ldap($c);
    my $r = $c->rendered;

    is $r->{status}, 409, 'refused — the new password could never take effect';
};

# ============================================
# Read side: the UI can only disable a field it is TOLD is env-owned. These
# lists used to be hand-written and incomplete (3 of 14 for ldap, 8 of 15 for
# saml), so the UI offered editable inputs for values the environment owned —
# the same lie, one request earlier.
# ============================================
subtest 'get_ldap / get_sso report every mappable key, not a subset' => sub {
    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    my %check = (
        ldap => sub { $_[0]->get_ldap($_[1]) },
        saml => sub { $_[0]->get_sso($_[1]) },
    );

    for my $section (sort keys %check) {
        my $c = mock_ctx();
        $check{$section}->($ctrl, $c);

        my @reported = sort keys %{ $c->rendered->{json}{from_env} };
        my @mappable = $settings->env_managed_keys($section);

        is_deeply \@reported, \@mappable,
            "$section reports all " . scalar(@mappable) . ' env-mappable keys';
    }
};

subtest 'backup GETs expose per-key locks the scalar flag cannot' => sub {
    # PURL_BACKUP_SCHEDULE_ENABLED is NOT set, so the old scalar `from_env`
    # says "nothing is locked" while retention really is. from_env_keys is the
    # additive per-key answer the UI needs to disable the right input.
    local $ENV{PURL_BACKUP_RETENTION_DAYS} = '90';
    delete local $ENV{PURL_BACKUP_SCHEDULE_ENABLED};

    my $settings = fresh_settings();
    my $ctrl     = backup_ctrl($settings);

    my $c = mock_ctx();
    $ctrl->get_schedule($c);
    my $schedule = $c->rendered->{json}{schedule};

    is $schedule->{from_env}, 0, 'the whole-panel flag is still 0 (unchanged contract)';
    is $schedule->{from_env_keys}{retention_days}, 1, 'but retention_days is reported locked';
    is $schedule->{from_env_keys}{schedule_enabled}, 0, 'and schedule_enabled is not';
};

subtest 'notification GET exposes per-key locks by dotted name' => sub {
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c        = mock_ctx();

    $ctrl->get_all($c);
    my $n = $c->rendered->{json}{notifications};

    is $n->{telegram}{from_env}, 0, 'per-channel flag unchanged';
    is $n->{from_env_keys}{'telegram.chat_id'}, 1, 'chat_id reported locked';
    is $n->{from_env_keys}{'telegram.bot_token'}, 0, 'bot_token is not';
};

subtest 'get_ldap marks the key the environment actually owns' => sub {
    local $ENV{PURL_LDAP_SEARCH_FILTER} = '(uid=%s)';

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);
    my $c        = mock_ctx();

    $ctrl->get_ldap($c);
    my $flags = $c->rendered->{json}{from_env};

    is $flags->{search_filter}, 1, 'search_filter locked';
    is $flags->{search_base},   0, 'search_base still editable';
};

done_testing();

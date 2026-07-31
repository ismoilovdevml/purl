#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json decode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Config;

# ============================================
# REGRESSION (#52): purge the ENV values that older builds baked into
# settings.json.
#
# Before #45/#59 every section write persisted the MERGED section, so any edit
# copied the environment's values for the other keys onto disk. That write path
# is closed, but what it already wrote stays: the Kubernetes Secret sits in
# plaintext on the config PVC, and that PVC is annotated resource-policy: keep,
# so even `helm uninstall` leaves it there. It is also actively confusing —
# ENV wins on read, so editing such a key looks saved and does nothing.
#
# The cleanup runs once at startup and is deliberately narrow:
#
#   remove the file's value ONLY when it is byte-identical to what the
#   environment currently supplies for that key.
#
# A DIFFERENT file value is the operator's own fallback — the value that comes
# back the day the variable is removed — and _writable_values exists to protect
# it. Deleting that would turn "unset PURL_TELEGRAM_CHAT_ID" into alerts that
# silently stop, which is the exact outage this codebase already fixed once.
# ============================================

my $dir = tempdir(CLEANUP => 1);
my $seq = 0;

my @ENV_KEYS = qw(
    PURL_CLICKHOUSE_PASSWORD PURL_CLICKHOUSE_HOST
    PURL_API_KEYS PURL_AUTH_ENABLED
    PURL_TELEGRAM_BOT_TOKEN PURL_TELEGRAM_CHAT_ID
    PURL_SLACK_WEBHOOK_URL
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    PURL_LDAP_BIND_PASSWORD PURL_RETENTION_DAYS
);

sub settings_with {
    my ($seed) = @_;
    my $file = File::Spec->catfile($dir, 'settings-' . ++$seq . '.json');
    open my $fh, '>', $file or die "cannot write $file: $!";
    print $fh encode_json($seed // {});
    close $fh;
    return (Purl::Config->new(config_file => $file), $file);
}

sub on_disk {
    my ($file) = @_;
    open my $fh, '<', $file or die "cannot read $file: $!";
    local $/;
    my $json = <$fh>;
    close $fh;
    return decode_json($json);
}

# Run the migration while capturing what it logged.
sub prune_capturing {
    my ($settings) = @_;
    my @logged;
    my $removed;
    {
        local $SIG{__WARN__} = sub { push @logged, $_[0] };
        $removed = $settings->prune_env_duplicates;
    }
    return ($removed, join('', @logged));
}

subtest 'a file value identical to the env value is removed' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'ch-secret';

    my ($settings, $file) = settings_with({
        clickhouse => { password => 'ch-secret', database => 'purl' },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, ['clickhouse.password'], 'reported as removed';

    ok !exists on_disk($file)->{clickhouse}{password},
        'the env copy is gone from settings.json';
    is on_disk($file)->{clickhouse}{database}, 'purl',
        'unrelated keys are untouched';
};

subtest 'a DIFFERENT file value is left alone' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'env-secret';

    my ($settings, $file) = settings_with({
        clickhouse => { password => 'the-operators-own-fallback' },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, [], 'nothing removed';
    is on_disk($file)->{clickhouse}{password}, 'the-operators-own-fallback',
        'the fallback that applies once the variable is unset survives';
};

subtest 'nested (dotted) keys are covered too' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_TELEGRAM_BOT_TOKEN} = 'tg-token';
    local $ENV{PURL_TELEGRAM_CHAT_ID}   = '-100999';

    my ($settings, $file) = settings_with({
        notifications => {
            telegram => {
                enabled   => 1,
                bot_token => 'tg-token',        # env duplicate
                chat_id   => 'FILE_CHAT',       # operator's own value
            },
        },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, ['notifications.telegram.bot_token'],
        'the nested duplicate is found by its dotted name';

    my $telegram = on_disk($file)->{notifications}{telegram};
    ok !exists $telegram->{bot_token}, 'duplicate removed';
    is $telegram->{chat_id}, 'FILE_CHAT', 'the differing sibling is kept';
    is $telegram->{enabled}, 1,           'and the channel toggle is kept';
};

subtest 'non-secret keys are covered as well' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_API_KEYS} = 'envkey1,envkey2';

    # Exactly the shape the old write path produced: the comma string from the
    # environment frozen into a field that normally holds a list.
    my ($settings, $file) = settings_with({
        auth => { api_keys => 'envkey1,envkey2', users => { admin => 'hash' } },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, ['auth.api_keys'], 'removed';
    ok !exists on_disk($file)->{auth}{api_keys}, 'gone from disk';
    is_deeply on_disk($file)->{auth}{users}, { admin => 'hash' }, 'users untouched';
};

subtest 'a genuine file list under an env shadow is not a duplicate' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_API_KEYS} = 'envkey1';

    my ($settings, $file) = settings_with({
        auth => { api_keys => [ { key => 'filekey1', label => 'ci' } ] },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, [], 'a structure can never equal an env string';
    is_deeply on_disk($file)->{auth}{api_keys}, [ { key => 'filekey1', label => 'ci' } ],
        'the stored list survives';
};

subtest 'nothing happens when the variable is not set' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        clickhouse => { password => 'ch-secret' },
    });

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, [], 'no env owner, no cleanup';
    is on_disk($file)->{clickhouse}{password}, 'ch-secret', 'file value intact';
};

subtest 'idempotent: the second run removes nothing and rewrites nothing' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'ch-secret';
    local $ENV{PURL_TELEGRAM_BOT_TOKEN}  = 'tg-token';

    my ($settings, $file) = settings_with({
        clickhouse    => { password => 'ch-secret' },
        notifications => { telegram => { bot_token => 'tg-token' } },
    });

    my ($first) = prune_capturing($settings);
    is_deeply [sort @$first], ['clickhouse.password', 'notifications.telegram.bot_token'],
        'first run cleans both';

    my @before = stat $file;
    sleep 1;    # make any rewrite observable in mtime

    # A FRESH Config, as a restart would build: the second run must decide from
    # the file, not from anything the first run left in memory.
    my $again = Purl::Config->new(config_file => $file);
    my ($second) = prune_capturing($again);

    is_deeply $second, [], 'second run finds nothing';
    my @after = stat $file;
    is $after[9], $before[9], 'and did not touch the file at all';
};

subtest 'the removed value is never written to the log' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'sup3r-s3cret-value';

    my ($settings) = settings_with({
        clickhouse => { password => 'sup3r-s3cret-value' },
    });

    my ($removed, $logged) = prune_capturing($settings);
    is_deeply $removed, ['clickhouse.password'], 'removed';

    like $logged, qr/clickhouse\.password/, 'the log names the key';
    unlike $logged, qr/sup3r-s3cret-value/, 'and never the value';
};

subtest 'reads are unchanged: ENV still wins, the file no longer ghosts' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        retention => { days => 90 },
    });

    {
        local $ENV{PURL_RETENTION_DAYS} = '90';
        my $cfg = Purl::Config->new(config_file => $file);
        prune_capturing($cfg);
        is $cfg->get('retention', 'days'), '90',
            'while the variable is set the effective value does not move';
    }

    # The variable comes off — which is the whole point. The ghost the old
    # write path left would have kept 90 in force silently; the default is what
    # an operator who never set retention in the UI should get back.
    my $after = Purl::Config->new(config_file => $file);
    is $after->get('retention', 'days'), 30,
        'with the variable gone the default applies, not a stale env copy';
};

subtest 'a config file that does not exist yet is not a failure' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'ch-secret';

    my $missing = File::Spec->catfile($dir, 'nonexistent-' . ++$seq . '.json');
    my $settings = Purl::Config->new(config_file => $missing);

    my ($removed) = prune_capturing($settings);
    is_deeply $removed, [], 'nothing to prune on a fresh install';
    ok !-e $missing, 'and no settings.json was created as a side effect';
};

# ============================================
# The migration is only useful if something RUNS it
# ============================================

# A pure unit test of prune_env_duplicates would pass just as happily with the
# call site missing, and a cleanup nobody calls fixes nothing on the installs
# that have the problem. So the real boot path is exercised once: the manager
# builds Purl::Config in setup_routes, before any worker forks.
subtest 'server startup prunes the duplicate' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'ch-secret';

    my (undef, $file) = settings_with({
        clickhouse => { password => 'ch-secret', database => 'purl' },
        retention  => { days => 45 },
    });
    local $ENV{PURL_CONFIG_FILE} = $file;

    {
        package Purl::Storage::Startup;    ## no critic (ProhibitMultiplePackages)
        use Moo;
        sub insert       { }
        sub insert_batch { }
        sub flush        { 1 }
        sub maybe_flush  { }
        sub search       { [] }
        sub count        { 0 }
        sub stats        { {} }
        sub field_stats  { [] }
        sub get_fields   { [] }
        sub get_metrics  { {} }
        sub _init_audit_schema { 1 }
        sub log_audit_event    { 1 }
    }

    require Purl::API::Server;
    my $storage = Purl::Storage::Startup->new;
    {
        no warnings 'redefine';    ## no critic (ProhibitNoWarnings)
        *Purl::API::Server::_build_storage = sub { return $storage };
    }
    Purl::API::Server->create(config => {})->setup_routes;

    my $disk = on_disk($file);
    ok !exists $disk->{clickhouse}{password},
        'booting the server removed the env duplicate from settings.json';
    is $disk->{clickhouse}{database}, 'purl', 'the rest of the section is intact';
    is $disk->{retention}{days}, 45, 'and an unrelated stored setting survived';
};

done_testing();

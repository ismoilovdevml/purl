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
# REGRESSION (#62): a write-only secret must be DELETABLE.
#
# %WRITE_ONLY keys are never handed back by their GET — the response carries a
# 0/1 "is it set" flag and nothing else. So the form field renders empty on
# every page load and comes back empty unless the admin retyped it, which is
# why an empty submission had to start meaning "I did not touch this" (#56).
#
# The price was that nothing meant "delete it". Disabling a channel
# (enabled => 0) leaves the token on the config PVC, and that PVC is annotated
# resource-policy: keep — so revoking a Telegram bot or rotating an S3 key had
# no way to actually remove the stored value.
#
# The fix is an EXPLICIT word for deletion, never a sentinel value: a sibling
# `clear_<field>: true` in the same request body. It applies to every
# %WRITE_ONLY key, it is refused with 409 when the environment owns the key,
# and it is refused with 400 for keys that are merely MASKED
# (ldap.bind_password, saml.sp_key, ai.api_key) — those come back as '********'
# so empty already means "clear it" for them, and that asymmetry is deliberate.
# ============================================

my $dir = tempdir(CLEANUP => 1);
my $seq = 0;

# Every env var that could otherwise decide a subtest's outcome. Each subtest
# starts from a known-empty environment and opts back in to what it needs.
my @ENV_KEYS = qw(
    PURL_CLICKHOUSE_PASSWORD
    PURL_TELEGRAM_BOT_TOKEN PURL_TELEGRAM_CHAT_ID
    PURL_SLACK_WEBHOOK_URL PURL_SLACK_CHANNEL
    PURL_ALERT_WEBHOOK_URL PURL_ALERT_WEBHOOK_TOKEN
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    PURL_BACKUP_S3_ENABLED PURL_LDAP_BIND_PASSWORD
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

sub settings_ctrl {
    return Purl::API::Controller::Settings->new(
        storage => mock_storage(), settings => $_[0]);
}

sub backup_ctrl {
    return Purl::API::Controller::Backup->new(
        storage => mock_storage(), settings => $_[0]);
}

# ============================================
# 1. The storage-layer contract: every %WRITE_ONLY key, none of the others
# ============================================

# section => key-within-section (dotted for the nested notification channels),
# exactly the eight entries of %WRITE_ONLY.
my @WRITE_ONLY = (
    [ clickhouse    => 'password' ],
    [ notifications => 'telegram.bot_token' ],
    [ notifications => 'telegram.chat_id' ],
    [ notifications => 'slack.webhook_url' ],
    [ notifications => 'webhook.url' ],
    [ notifications => 'webhook.auth_token' ],
    [ backup        => 's3_access_key' ],
    [ backup        => 's3_secret_key' ],
);

subtest 'clear_secrets erases every write-only key, not just one' => sub {
    delete local @ENV{@ENV_KEYS};

    for my $pair (@WRITE_ONLY) {
        my ($section, $key) = @$pair;

        my ($settings, $file) = settings_with({
            clickhouse    => { password => 'SECRET', host => 'keep-me' },
            backup        => { s3_access_key => 'SECRET', s3_secret_key => 'SECRET',
                               s3_bucket => 'keep-me' },
            notifications => {
                telegram => { enabled => 1, bot_token => 'SECRET', chat_id => 'SECRET' },
                slack    => { enabled => 1, webhook_url => 'SECRET', channel => 'keep-me' },
                webhook  => { enabled => 1, url => 'SECRET', auth_token => 'SECRET' },
            },
        });

        ok $settings->is_clearable($section, $key),
            "$section.$key is declared clearable";

        my $cleared = $settings->clear_secrets($section, $key);
        is_deeply $cleared, [$key], "$section.$key reports itself cleared";

        # Walk the dotted path on disk and prove the leaf is gone.
        my $node = on_disk($file)->{$section};
        my @path = split /\./, $key;
        my $leaf = pop @path;
        $node = $node->{$_} for @path;
        ok !exists $node->{$leaf}, "$section.$key was removed from settings.json";
    }
};

subtest 'a key that is only MASKED is not clearable through this path' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings) = settings_with({ ldap => { bind_password => 'stored' } });

    ok !$settings->is_clearable('ldap', 'bind_password'),
        'ldap.bind_password is masked, not write-only — empty already clears it';
    ok !$settings->is_clearable('saml', 'sp_key'),      'saml.sp_key likewise';
    ok !$settings->is_clearable('ai',   'api_key'),     'ai.api_key likewise';
    ok !$settings->is_clearable('notifications', 'slack.channel'),
        'and a plain non-secret key is not clearable either';

    is_deeply $settings->clear_secrets('ldap', 'bind_password'), [],
        'clear_secrets refuses to touch it even if asked directly';
};

subtest 'clear_secrets is idempotent and never resurrects the value' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        notifications => { telegram => { enabled => 1, bot_token => 'SECRET' } },
    });

    is_deeply $settings->clear_secrets('notifications', 'telegram.bot_token'),
        ['telegram.bot_token'], 'first call clears';
    is_deeply $settings->clear_secrets('notifications', 'telegram.bot_token'),
        [], 'second call is a no-op, not an error';

    ok !exists on_disk($file)->{notifications}{telegram}{bot_token},
        'still gone';
};

subtest 'clear_secrets will not delete a key the environment owns' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'env-secret';

    my ($settings, $file) = settings_with({ clickhouse => { password => 'file-secret' } });

    is_deeply $settings->clear_secrets('clickhouse', 'password'), [],
        'refused at the storage layer too, not only at the endpoint';
    is on_disk($file)->{clickhouse}{password}, 'file-secret',
        'the file fallback the environment shadows is intact';
};

# ============================================
# 2. The HTTP contract
# ============================================

subtest 'notifications: clear_bot_token deletes the stored token' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        notifications => {
            telegram => { enabled => 1, bot_token => 'REAL_TOKEN', chat_id => 'CHAT' },
        },
    });

    # Exactly what the panel posts: the empty field the UI always renders, PLUS
    # the explicit instruction.
    my $c = mock_ctx(
        body   => encode_json({
            enabled          => 0,
            bot_token        => '',
            chat_id          => '',
            clear_bot_token  => \1,
        }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings)->update_notifications($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is_deeply $c->rendered->{json}{cleared}, ['telegram.bot_token'],
        'the response names what it deleted';

    my $telegram = on_disk($file)->{notifications}{telegram};
    ok !exists $telegram->{bot_token}, 'the token is gone from settings.json';
    is $telegram->{chat_id}, 'CHAT',
        'and the sibling secret the admin did NOT clear is untouched';
    ok !exists $telegram->{clear_bot_token},
        'the instruction itself was never persisted as a config key';
};

subtest 'without the flag an empty field still means "untouched" (#56 holds)' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        notifications => { telegram => { enabled => 1, bot_token => 'REAL_TOKEN' } },
    });

    my $c = mock_ctx(
        body   => encode_json({ enabled => 0, bot_token => '', chat_id => '' }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings)->update_notifications($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is on_disk($file)->{notifications}{telegram}{bot_token}, 'REAL_TOKEN',
        'the token survives — deletion needs the explicit word';
};

subtest 'clickhouse: clear_password deletes the stored password' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        clickhouse => { host => 'old-host', password => 'stored-secret' },
    });

    my $c = mock_ctx(body => encode_json({
        host           => 'new-host',
        password       => '',
        clear_password => \1,
    }));
    settings_ctrl($settings)->update_clickhouse($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is on_disk($file)->{clickhouse}{host}, 'new-host', 'the ordinary edit landed';
    ok !exists on_disk($file)->{clickhouse}{password}, 'and the password is gone';
};

subtest 'backup: both S3 credentials can be cleared in one request' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        backup => {
            s3_bucket     => 'my-bucket',
            s3_access_key => 'AKIASTORED',
            s3_secret_key => 'SECRETSTORED',
        },
    });

    my $c = mock_ctx(body => encode_json({
        s3_bucket            => 'my-bucket',
        s3_access_key        => '',
        s3_secret_key        => '',
        clear_s3_access_key  => \1,
        clear_s3_secret_key  => \1,
    }));
    backup_ctrl($settings)->update_s3_config($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is_deeply [sort @{ $c->rendered->{json}{cleared} }],
        ['s3_access_key', 's3_secret_key'], 'both named in the response';

    my $backup = on_disk($file)->{backup};
    ok !exists $backup->{s3_access_key}, 'access key gone';
    ok !exists $backup->{s3_secret_key}, 'secret key gone';
    is $backup->{s3_bucket}, 'my-bucket', 'the non-secret setting is intact';
};

subtest 'clearing an ENV-owned key is a 409 and changes nothing' => sub {
    delete local @ENV{@ENV_KEYS};
    local $ENV{PURL_TELEGRAM_BOT_TOKEN} = 'env-token';

    my ($settings, $file) = settings_with({
        notifications => { telegram => { enabled => 1, bot_token => 'FILE_TOKEN' } },
    });

    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, bot_token => '', clear_bot_token => \1 }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings)->update_notifications($c);

    is $c->rendered->{status}, 409, 'refused — the environment owns the value'
        or diag explain $c->rendered;
    is_deeply $c->rendered->{json}{from_env}, ['telegram.bot_token'], 'and says which key';

    is on_disk($file)->{notifications}{telegram}{bot_token}, 'FILE_TOKEN',
        'the file fallback was not deleted behind a 409';
};

subtest 'a clear flag for a key that is not a write-only secret is a 400' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings) = settings_with();
    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, clear_channel => \1 }),
        params => { type => 'slack' },
    );
    settings_ctrl($settings)->update_notifications($c);

    is $c->rendered->{status}, 400, 'refused as a bad request'
        or diag explain $c->rendered;
    like $c->rendered->{json}{error}, qr/slack\.channel/,
        'and names the offending field';
};

subtest 'clear plus a retyped value in the same request is a 400' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        clickhouse => { password => 'stored-secret' },
    });

    my $c = mock_ctx(body => encode_json({
        password       => 'a-new-password',
        clear_password => \1,
    }));
    settings_ctrl($settings)->update_clickhouse($c);

    is $c->rendered->{status}, 400, 'contradictory instructions are refused'
        or diag explain $c->rendered;
    is on_disk($file)->{clickhouse}{password}, 'stored-secret',
        'and nothing was written either way';
};

subtest 'a false clear flag is not an instruction to delete' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        clickhouse => { password => 'stored-secret' },
    });

    my $c = mock_ctx(body => encode_json({
        password       => '',
        clear_password => \0,
    }));
    settings_ctrl($settings)->update_clickhouse($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is on_disk($file)->{clickhouse}{password}, 'stored-secret',
        'the password survives a false flag';
    is_deeply $c->rendered->{json}{cleared}, [], 'and nothing is reported cleared';
};

subtest 'the masked keys keep clearing on empty — the asymmetry is intact' => sub {
    delete local @ENV{@ENV_KEYS};

    my ($settings, $file) = settings_with({
        ldap => { bind_password => 'stored', server => 'ldap://x', bind_dn => 'cn=a',
                  search_base => 'dc=x' },
    });

    my $c = mock_ctx(body => encode_json({ bind_password => '', search_base => 'dc=y' }));
    settings_ctrl($settings)->update_ldap($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is on_disk($file)->{ldap}{bind_password}, '',
        'an empty masked field still clears the value, no flag needed';
};

done_testing();

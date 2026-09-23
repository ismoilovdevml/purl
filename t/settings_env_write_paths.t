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
use Purl::API::Controller::Settings::Notifications;
use Purl::API::Controller::Settings::LDAP;
use Purl::API::Controller::Backup;

# ============================================
# REGRESSION: what happens on the WRITE side once the ENV guard has let a
# request through.
#
# t/settings_env_shadow.t pins the refusal (409 for an edit the environment
# owns). This file pins the other half, which the refusal made reachable:
#
#   1. an ENV-shadowed key keeps the value the FILE holds. ENV wins on read
#      today, but the day the variable is removed the file value is what comes
#      back — deleting it turns "unset the env var" into a silent outage.
#   2. a key whose GET never hands the value back (a secret rendered as a
#      0/1 "is it set" flag) comes back from the UI EMPTY. Empty means "I did
#      not retype it", not "change it to nothing" — treating it as an edit
#      409s every save of a panel the admin cannot fix, because the field they
#      would have to correct was never populated.
#   3. ENV-owned values never reach settings.json, whichever writer is used.
#      set_section strips them; set() used not to, so a no-op resubmit froze
#      the environment's value into the file as a ghost.
#   4. "true" from the environment and 1 from a JSON body are the same
#      boolean. Comparing them as strings makes an honest GET->PUT round-trip
#      unsaveable.
# ============================================

my $dir = tempdir(CLEANUP => 1);
my $seq = 0;

# A settings.json seeded with $seed (file-held values), plus the Config that
# reads it. Each call gets its own file so a leftover from an earlier subtest
# can never explain a pass.
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

# One controller per settings section (Purl::API::Controller::Settings::*);
# no section is the overview / ClickHouse / retention controller.
sub settings_ctrl {
    my ($settings, $section) = @_;
    my $class = "Purl::API::Controller::Settings" . ($section ? "::$section" : "");
    return $class->new(storage => mock_storage(), settings => $settings);
}

sub backup_ctrl {
    return Purl::API::Controller::Backup->new(
        storage => mock_storage(), settings => $_[0]);
}

# ============================================
# 1. The file value under an ENV shadow is kept, not deleted
# ============================================

subtest 'a notifications save keeps the file value the env shadows' => sub {
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my ($settings, $file) = settings_with({
        notifications => {
            telegram => { enabled => 1, chat_id => 'FILE_CHAT', bot_token => 'OLD' },
        },
    });

    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, bot_token => 'NEW_TOKEN' }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings, 'Notifications')->update_notifications($c);

    is $c->rendered->{json}{status}, 'ok', 'the save is accepted';

    my $telegram = on_disk($file)->{notifications}{telegram};
    is $telegram->{chat_id}, 'FILE_CHAT',
        'the env-shadowed chat_id still holds the FILE value';
    is $telegram->{bot_token}, 'NEW_TOKEN', 'and the edited key was written';

    isnt $telegram->{chat_id}, '-100999',
        'the environment secret was not copied into settings.json';
};

subtest 'the flat sections already behaved this way (the invariant copied)' => sub {
    # set_section/_writable_values has always RESTORED the file value rather
    # than dropping it. Pinning it next to the nested case is what stops the two
    # paths drifting apart again.
    local $ENV{PURL_LDAP_BIND_DN} = 'cn=env,dc=x';

    my ($settings, $file) = settings_with({
        ldap => { bind_dn => 'cn=file', search_base => 'dc=old' },
    });

    my $c = mock_ctx(body => encode_json({ search_base => 'dc=new' }));
    settings_ctrl($settings, 'LDAP')->update_ldap($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted';
    is on_disk($file)->{ldap}{bind_dn}, 'cn=file', 'file bind_dn survived';
};

# ============================================
# 2. A blank value for a key the GET never reveals is not an edit
#
# Every call site of reject_env_managed is covered here, because the previous
# four times this class of bug shipped it was fixed at one site and not its
# siblings.
# ============================================

subtest 'notifications: the UI sends "" for secrets it never received' => sub {
    # NotificationSettings holds bot_token/chat_id at '' until the admin types,
    # because get_all only ever reports whether they are SET. With
    # PURL_TELEGRAM_CHAT_ID set and PURL_TELEGRAM_BOT_TOKEN not (the chart
    # templates them independently), every save of the panel used to 409 — and
    # the admin could not fix it, having never been shown the value.
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my ($settings) = settings_with();
    my $c = mock_ctx(
        body   => encode_json({ enabled => 1, bot_token => '', chat_id => '' }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings, 'Notifications')->update_notifications($c);

    my $r = $c->rendered;
    isnt $r->{status}, 409, 'not refused — nothing was actually edited'
        or diag explain $r;
    is $r->{json}{status}, 'ok', 'the panel saves';
};

subtest 'a blank secret does not wipe the one already stored' => sub {
    # The other half of the same rule, and the reason it cannot stop at the
    # 409: once the save is accepted, writing the blank would delete a token
    # the admin never touched — trading "the panel refuses to save" for
    # "Telegram alerts stopped and nobody edited them".
    local $ENV{PURL_TELEGRAM_CHAT_ID} = '-100999';
    delete local $ENV{PURL_TELEGRAM_BOT_TOKEN};

    my ($settings, $file) = settings_with({
        notifications => {
            telegram => { enabled => 1, bot_token => 'REAL_TOKEN' },
        },
    });

    my $c = mock_ctx(
        body   => encode_json({ enabled => 0, bot_token => '', chat_id => '' }),
        params => { type => 'telegram' },
    );
    settings_ctrl($settings, 'Notifications')->update_notifications($c);

    is $c->rendered->{json}{status}, 'ok', 'saved';

    my $telegram = on_disk($file)->{notifications}{telegram};
    is $telegram->{bot_token}, 'REAL_TOKEN', 'the untouched token survived';
    is $telegram->{enabled}, 0, 'and the toggle the admin DID change was written';
};

subtest 'clickhouse: an untouched password survives a host edit' => sub {
    # No ENV involved: the ClickHouse form always renders an empty password box
    # (get_all reports password_set, never the value), so every host edit posts
    # password => '' and used to overwrite the stored one with nothing.
    delete local $ENV{PURL_CLICKHOUSE_PASSWORD};

    my ($settings, $file) = settings_with({
        clickhouse => { host => 'old-host', password => 'stored-secret' },
    });

    my $c = mock_ctx(body => encode_json({ host => 'new-host', password => '' }));
    settings_ctrl($settings)->update_clickhouse($c);

    is on_disk($file)->{clickhouse}{host}, 'new-host', 'the edit landed';
    is on_disk($file)->{clickhouse}{password}, 'stored-secret',
        'and the password was not blanked';
};

subtest 'clickhouse: password_set is a flag, so "" means untouched' => sub {
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'env-secret';

    my ($settings, $file) = settings_with();
    my $c = mock_ctx(body => encode_json({
        host     => 'new-host',
        port     => 8123,
        database => 'purl',
        user     => 'default',
        password => '',
    }));
    settings_ctrl($settings)->update_clickhouse($c);

    my $r = $c->rendered;
    isnt $r->{status}, 409, 'not refused' or diag explain $r;
    is on_disk($file)->{clickhouse}{host}, 'new-host', 'the real edit was saved';
    ok !exists on_disk($file)->{clickhouse}{password},
        'and the env password was not written to disk';
};

subtest 'backup s3: credentials are write-only, so "" means untouched' => sub {
    local $ENV{AWS_SECRET_ACCESS_KEY} = 'env-secret';
    delete local $ENV{PURL_BACKUP_S3_ENABLED};

    my ($settings, $file) = settings_with();
    my $c = mock_ctx(body => encode_json({
        s3_bucket     => 'my-bucket',
        s3_secret_key => '',
    }));
    backup_ctrl($settings)->update_s3_config($c);

    my $r = $c->rendered;
    isnt $r->{status}, 409, 'not refused' or diag explain $r;
    is on_disk($file)->{backup}{s3_bucket}, 'my-bucket', 'the real edit was saved';
};

subtest 'a retyped secret is still refused' => sub {
    # The blank exemption must not become a hole: a value the admin actually
    # typed cannot take effect while the environment owns the key, so it is
    # still a 409.
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'env-secret';

    my ($settings) = settings_with();
    my $c = mock_ctx(body => encode_json({ password => 'typed-by-admin' }));
    settings_ctrl($settings)->update_clickhouse($c);

    is $c->rendered->{status}, 409, 'refused';
    is_deeply $c->rendered->{json}{from_env}, ['password'], 'named';
};

# ============================================
# 3. ENV-owned values never land in settings.json, whichever writer runs
# ============================================

subtest 'set() does not persist a key the environment owns' => sub {
    local $ENV{PURL_BACKUP_RETENTION_DAYS} = '90';

    my ($settings, $file) = settings_with({ backup => { retention_days => 7 } });

    ok $settings->set('backup', 'retention_days', 30), 'the call still succeeds';

    is on_disk($file)->{backup}{retention_days}, 7,
        'the FILE value is untouched — no env ghost written';
    is $settings->get('backup', 'retention_days'), '90',
        'and the environment is still what is in effect';
};

subtest 'update_s3_config no-op resubmit does not freeze the env credential' => sub {
    # The UI PUTs the whole form back. s3_access_key comes back equal to the
    # effective (env) value, which is not a change and is accepted — but going
    # through set() it used to be WRITTEN, so removing AWS_ACCESS_KEY_ID later
    # left a stale credential silently in force.
    local $ENV{AWS_ACCESS_KEY_ID} = 'AKIAENV';
    delete local $ENV{PURL_BACKUP_S3_ENABLED};

    my ($settings, $file) = settings_with();
    my $c = mock_ctx(body => encode_json({
        s3_access_key => 'AKIAENV',
        s3_bucket     => 'my-bucket',
    }));
    backup_ctrl($settings)->update_s3_config($c);

    is $c->rendered->{json}{status}, 'ok', 'accepted as a no-op';
    ok !exists on_disk($file)->{backup}{s3_access_key},
        'the env credential is not in settings.json';
    is on_disk($file)->{backup}{s3_bucket}, 'my-bucket', 'the real edit is';
};

# ============================================
# 4. "true" (env) and 1 (JSON) are the same boolean
# ============================================

subtest 'PURL_BACKUP_SCHEDULE_ENABLED=true accepts a JSON true round-trip' => sub {
    local $ENV{PURL_BACKUP_SCHEDULE_ENABLED} = 'true';

    my ($settings) = settings_with();
    my $c = mock_ctx(body => encode_json({ enabled => \1, interval_hours => 24 }));
    backup_ctrl($settings)->update_schedule($c);

    my $r = $c->rendered;
    isnt $r->{status}, 409, 'the honest GET->PUT round-trip is not a conflict'
        or diag explain $r;
    is $r->{json}{status}, 'ok', 'saved';
};

subtest 'PURL_LDAP_TLS_ENABLED=true accepts 1 and still refuses 0' => sub {
    local $ENV{PURL_LDAP_TLS_ENABLED} = 'true';

    my ($settings) = settings_with();
    my $c = mock_ctx(body => encode_json({ tls_enabled => 1 }));
    settings_ctrl($settings, 'LDAP')->update_ldap($c);
    isnt $c->rendered->{status}, 409, '1 means the same as "true"'
        or diag explain $c->rendered;

    my ($settings2) = settings_with();
    my $c2 = mock_ctx(body => encode_json({ tls_enabled => \0 }));
    settings_ctrl($settings2, 'LDAP')->update_ldap($c2);
    is $c2->rendered->{status}, 409,
        'turning it OFF is a real change and is still refused';
};

done_testing();

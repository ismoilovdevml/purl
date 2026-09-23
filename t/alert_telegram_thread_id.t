#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json decode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

use PurlTest::Mock qw(mock_ctx mock_storage);

use Purl::Config;
use Purl::Alert::Telegram;
use Purl::API::Controller::Settings;
use Purl::API::Controller::Settings::Notifications;
require Purl::API::Server;

# ============================================
# REGRESSION (#71): Telegram thread_id was a ghost field.
#
# `grep -rn thread_id lib/` returned NOTHING. The UI collected it,
# update_notifications wrote it verbatim into settings.json, and no code path
# ever read it back — Purl::Alert::Telegram never sent it, so an admin who
# pointed Purl at a forum topic got their alerts in the group's General topic
# and no error to explain why.
#
# It was also unhydratable: the settings GET did not return it, so the panel
# rendered the input empty and the next save of ANY Telegram field posted
# thread_id: "" back over the stored value (#68's silent-rewrite pattern).
#
# Implemented rather than removed: Telegram forum routing is one optional
# `message_thread_id` on the sendMessage payload the channel already builds —
# a ~5 line reach, against removing a field users have already filled in.
#
# What this file pins:
#   1. deliver() sends message_thread_id when a thread is configured...
#   2. ...as a JSON NUMBER (Telegram rejects a string), and never as an empty
#      or malformed value.
#   3. The settings GET returns the stored thread_id, so the UI can hydrate it
#      and a later save cannot blank it.
#   4. A malformed thread_id is refused at the API boundary instead of being
#      stored to do nothing.
#   5. PURL_TELEGRAM_THREAD_ID owns the field like every other mapped key.
#   6. _build_notifiers() actually wires the configured thread through — the
#      step whose absence made every layer below it pointless.
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

# Drive PUT /api/settings/notifications/telegram with $body, through the
# notifications controller over the same Purl::Config as $ctrl.
sub save_telegram {
    my ($ctrl, $body) = @_;
    my $notifications = Purl::API::Controller::Settings::Notifications->new(
        storage  => mock_storage(),
        settings => $ctrl->settings,
    );
    my $c = mock_ctx(
        body   => encode_json($body),
        params => { type => 'telegram' },
    );
    $notifications->update_notifications($c);
    return $c->rendered;
}

# Capture the sendMessage payload deliver() would put on the wire.
sub captured_send {
    my (%args) = @_;

    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $raw;
    $http_mock->redefine('post', sub {
        $raw = $_[2]->{content};
        return { success => 1, status => 200, content => '{"ok":true}' };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test-tg',
        bot_token => 'TOKEN',
        chat_id   => '-1001234567890',
        %args,
    );

    $t->deliver({
        alert     => 'High Error Rate',
        query     => 'level:ERROR',
        count     => 15,
        threshold => 10,
        window    => 5,
        time      => 'now',
        severity  => 'critical',
    });

    return ($raw, decode_json($raw));
}

subtest 'deliver routes to the forum topic when a thread is configured' => sub {
    my ($raw, $payload) = captured_send(thread_id => '42');

    is $payload->{message_thread_id}, 42,
        'message_thread_id rides along on sendMessage';
    like $raw, qr/"message_thread_id":\s*42(?!")/,
        'as a JSON number — Telegram rejects a quoted thread id';
};

subtest 'deliver omits the field entirely when no thread is configured' => sub {
    my ($raw, $payload) = captured_send();

    ok !exists $payload->{message_thread_id},
        'no message_thread_id key at all';
    is $payload->{chat_id}, '-1001234567890', 'the ordinary payload is intact';
};

subtest 'a blank or malformed thread_id is left out, not sent as-is' => sub {
    for my $bad ('', '   ', 'general', '0', '-5') {
        my (undef, $payload) = captured_send(thread_id => $bad);
        ok !exists $payload->{message_thread_id},
            "thread_id '$bad' is not put on the wire";
    }
};

subtest 'the settings GET returns thread_id so the UI can hydrate it' => sub {
    delete local $ENV{PURL_TELEGRAM_THREAD_ID};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    my $saved = save_telegram($ctrl, {
        enabled   => 1,
        bot_token => '123456:ABC-DEF',
        chat_id   => '-1001234567890',
        thread_id => '77',
    });
    is $saved->{json}{status}, 'ok', 'the save was accepted';

    my $c = mock_ctx();
    $ctrl->get_all($c);
    my $telegram = $c->rendered->{json}{notifications}{telegram};

    is $telegram->{thread_id}, '77',
        'the stored thread id comes back — it is a routing value, not a secret';
};

subtest 'a hydrated resave keeps the thread id' => sub {
    delete local $ENV{PURL_TELEGRAM_THREAD_ID};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    save_telegram($ctrl, {
        enabled   => 1,
        bot_token => '123456:ABC-DEF',
        chat_id   => '-1001234567890',
        thread_id => '77',
    });

    # The panel reloads, hydrates thread_id from the GET, the admin toggles
    # something else and saves. The thread must survive.
    my $c = mock_ctx();
    $ctrl->get_all($c);
    my $hydrated = $c->rendered->{json}{notifications}{telegram}{thread_id};

    save_telegram($ctrl, {
        enabled   => 0,
        bot_token => '',
        chat_id   => '',
        thread_id => $hydrated,
    });

    is $settings->get_nested('notifications', 'telegram', 'thread_id'), '77',
        'still 77 after the second save';
};

subtest 'a malformed thread_id is refused, not stored to do nothing' => sub {
    delete local $ENV{PURL_TELEGRAM_THREAD_ID};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    my $r = save_telegram($ctrl, {
        enabled   => 1,
        bot_token => '123456:ABC-DEF',
        chat_id   => '-1001234567890',
        thread_id => 'not-a-topic',
    });

    is $r->{status}, 400, 'refused at the API boundary'
        or diag explain $r;
    ok !$settings->get_nested('notifications', 'telegram', 'thread_id'),
        'and nothing was written';
};

subtest 'an empty thread_id is accepted — it means "no topic"' => sub {
    delete local $ENV{PURL_TELEGRAM_THREAD_ID};

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    my $r = save_telegram($ctrl, {
        enabled   => 1,
        bot_token => '123456:ABC-DEF',
        chat_id   => '-1001234567890',
        thread_id => '',
    });

    is $r->{json}{status}, 'ok', 'clearing the topic is a legitimate edit';
};

subtest 'PURL_TELEGRAM_THREAD_ID owns the field like every other mapped key' => sub {
    local $ENV{PURL_TELEGRAM_THREAD_ID} = '99';

    my $settings = fresh_settings();
    my $ctrl     = settings_ctrl($settings);

    my $c = mock_ctx();
    $ctrl->get_all($c);
    is $c->rendered->{json}{notifications}{from_env_keys}{'telegram.thread_id'}, 1,
        'the GET reports the lock';

    my $r = save_telegram($ctrl, { thread_id => '11' });
    is $r->{status}, 409, 'and the write is refused instead of silently dropped';
};

subtest '_build_notifiers wires the thread through to the channel' => sub {
    # The step whose absence made the whole field a ghost: even a correctly
    # stored thread id does nothing unless the notifier is built with it.
    local $ENV{PURL_TELEGRAM_BOT_TOKEN} = '123456:ABC-DEF';
    local $ENV{PURL_TELEGRAM_CHAT_ID}   = '-1001234567890';
    local $ENV{PURL_TELEGRAM_THREAD_ID} = '55';

    my $notifiers = Purl::API::Server::_build_notifiers();

    ok $notifiers->{telegram}, 'a telegram notifier was built';
    is $notifiers->{telegram}->thread_id, '55',
        'carrying the configured forum topic';
};

done_testing;

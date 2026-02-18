#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Alert::Telegram;

# ============================================
# Constructor
# ============================================
subtest 'constructor with required params' => sub {
    my $t = Purl::Alert::Telegram->new(
        name      => 'test-tg',
        bot_token => '123456:ABC-DEF',
        chat_id   => '-1001234567890',
    );
    is $t->name, 'test-tg', 'name set';
    is $t->bot_token, '123456:ABC-DEF', 'bot_token set';
    is $t->chat_id, '-1001234567890', 'chat_id set';
    is $t->parse_mode, 'HTML', 'default parse_mode is HTML';
};

# ============================================
# deliver — mocked HTTP
# ============================================
subtest 'deliver success' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $captured_url;
    my $captured_body;

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_url = $url;
        $captured_body = $opts->{content};
        return { success => 1, status => 200, content => '{"ok":true}' };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'BOT_TOKEN',
        chat_id   => '12345',
    );

    my $result = $t->deliver({
        alert     => 'High Error Rate',
        query     => 'level:ERROR',
        count     => 15,
        threshold => 10,
        window    => 5,
        time      => '2025-01-01',
        severity  => 'critical',
    });

    ok $result, 'deliver returned truthy';
    like $captured_url, qr{api\.telegram\.org/botBOT_TOKEN/sendMessage}, 'correct API URL';
    like $captured_body, qr/"chat_id".*"12345"/, 'chat_id in payload';
};

subtest 'deliver failure' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub {
        return { success => 0, status => 401, content => 'Unauthorized' };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'BAD_TOKEN',
        chat_id   => '12345',
    );

    my $result = $t->deliver({
        alert => 'Test', severity => 'warning',
        count => 1, threshold => 1, window => 5, time => 'now',
    });
    ok !$result, 'deliver returns 0 on failure';
};

# ============================================
# _format_telegram_message
# ============================================
subtest 'message format contains expected fields' => sub {
    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'TOKEN',
        chat_id   => '123',
    );

    my $text = $t->_format_telegram_message({
        alert     => 'Test Alert',
        query     => 'level:ERROR',
        count     => 20,
        threshold => 10,
        window    => 5,
        time      => '2025-01-01 12:00',
        severity  => 'critical',
    });

    like $text, qr/PURL ALERT/, 'contains PURL ALERT header';
    like $text, qr/Test Alert/, 'contains alert name';
    like $text, qr/level:ERROR/, 'contains query';
    like $text, qr/CRITICAL/, 'contains severity';
    like $text, qr/20/, 'contains count';
    like $text, qr/10/, 'contains threshold';
};

subtest 'HTML escaping in message' => sub {
    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'TOKEN',
        chat_id   => '123',
    );

    my $text = $t->_format_telegram_message({
        alert     => '<script>alert("xss")</script>',
        query     => 'a > b && c < d',
        count     => 1,
        threshold => 1,
        window    => 5,
        time      => 'now',
        severity  => 'warning',
    });

    unlike $text, qr/<script>/, 'HTML tags escaped';
    like $text, qr/&lt;script&gt;/, 'angle brackets properly escaped';
    like $text, qr/&amp;/, 'ampersands escaped';
};

# ============================================
# test — connection test
# ============================================
subtest 'test success' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('get', sub {
        return {
            success => 1,
            status  => 200,
            content => '{"ok":true,"result":{"id":123,"is_bot":true,"username":"testbot"}}',
        };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'TOKEN',
        chat_id   => '123',
    );

    my $result = $t->test;
    ok $result, 'test returns result';
    is $result->{username}, 'testbot', 'bot username returned';
};

subtest 'test failure' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('get', sub {
        return { success => 0, status => 401, content => '{"ok":false}' };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'BAD_TOKEN',
        chat_id   => '123',
    );

    my $result = $t->test;
    ok !$result, 'test returns falsy on failure';
};

# ============================================
# send_test — sends test alert message
# ============================================
subtest 'send_test calls deliver' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $delivered = 0;
    $http_mock->redefine('post', sub {
        $delivered = 1;
        return { success => 1, status => 200 };
    });

    my $t = Purl::Alert::Telegram->new(
        name      => 'test',
        bot_token => 'TOKEN',
        chat_id   => '123',
    );

    my $result = $t->send_test;
    ok $result, 'send_test succeeds';
    ok $delivered, 'deliver was called';
};

done_testing;

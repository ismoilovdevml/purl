#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Alert::Slack;

# ============================================
# Constructor
# ============================================
subtest 'constructor defaults' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test-slack',
        webhook_url => 'https://hooks.slack.com/services/T00/B00/XXX',
    );
    is $s->name, 'test-slack', 'name set';
    is $s->webhook_url, 'https://hooks.slack.com/services/T00/B00/XXX', 'webhook_url set';
    is $s->channel, '', 'default channel empty';
    is $s->username, 'Purl Alert', 'default username';
    is $s->icon_emoji, ':warning:', 'default icon';
};

subtest 'constructor with channel' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
        channel     => '#alerts',
    );
    is $s->channel, '#alerts', 'custom channel set';
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
        return { success => 1, status => 200, content => 'ok' };
    });

    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/services/T00/B00/XXX',
        channel     => '#monitoring',
    );

    my $result = $s->deliver({
        alert     => 'High Error Rate',
        query     => 'level:ERROR',
        count     => 15,
        threshold => 10,
        window    => 5,
        time      => '2025-01-01',
        severity  => 'critical',
    });

    ok $result, 'deliver succeeded';
    is $captured_url, 'https://hooks.slack.com/services/T00/B00/XXX', 'posted to webhook URL';
    like $captured_body, qr/"username".*"Purl Alert"/, 'username in payload';
    like $captured_body, qr/#monitoring/, 'channel in payload';
};

subtest 'deliver failure' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub {
        return { success => 0, status => 500, content => 'error' };
    });

    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $result = $s->deliver({
        alert => 'Test', severity => 'warning',
        count => 1, threshold => 1, window => 5, time => 'now',
    });
    ok !$result, 'deliver returns 0 on HTTP failure';
};

# ============================================
# _format_slack_message
# ============================================
subtest 'slack message structure' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $payload = $s->_format_slack_message({
        alert     => 'Test Alert',
        query     => 'level:ERROR',
        count     => 20,
        threshold => 10,
        window    => 5,
        time      => '2025-01-01',
        severity  => 'critical',
    });

    is ref $payload, 'HASH', 'payload is hash';
    is $payload->{username}, 'Purl Alert', 'username set';
    ok exists $payload->{attachments}, 'has attachments';
    is ref $payload->{attachments}, 'ARRAY', 'attachments is array';

    my $att = $payload->{attachments}[0];
    is $att->{color}, '#dc3545', 'critical = red color';
    like $att->{title}, qr/Test Alert/, 'title contains alert name';
    ok scalar(@{$att->{fields}}) >= 4, 'has multiple fields';
};

subtest 'slack message warning severity' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $payload = $s->_format_slack_message({
        alert => 'Test', severity => 'warning',
        count => 1, threshold => 1, window => 5, time => 'now',
    });

    is $payload->{attachments}[0]{color}, '#ffc107', 'warning = yellow color';
};

subtest 'slack channel included when set' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
        channel     => '#ops',
    );

    my $payload = $s->_format_slack_message({
        alert => 'T', severity => 'warning',
        count => 1, threshold => 1, window => 5, time => 'now',
    });

    is $payload->{channel}, '#ops', 'channel set in payload';
};

subtest 'slack channel not set when empty' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $payload = $s->_format_slack_message({
        alert => 'T', severity => 'warning',
        count => 1, threshold => 1, window => 5, time => 'now',
    });

    ok !exists $payload->{channel}, 'no channel when empty';
};

subtest 'slack escaping' => sub {
    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $payload = $s->_format_slack_message({
        alert     => '<script>XSS</script>',
        query     => 'a & b > c',
        count     => 1,
        threshold => 1,
        window    => 5,
        time      => 'now',
        severity  => 'warning',
    });

    unlike $payload->{attachments}[0]{title}, qr/<script>/, 'HTML escaped in title';
};

# ============================================
# send_test
# ============================================
subtest 'send_test calls deliver' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $called = 0;
    $http_mock->redefine('post', sub {
        $called = 1;
        return { success => 1, status => 200 };
    });

    my $s = Purl::Alert::Slack->new(
        name        => 'test',
        webhook_url => 'https://hooks.slack.com/test',
    );

    my $result = $s->send_test;
    ok $result, 'send_test succeeds';
    ok $called, 'HTTP POST called';
};

done_testing;

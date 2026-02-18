#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Alert::Webhook;
use Digest::SHA qw(hmac_sha256_hex);
use JSON::XS ();

my $json = JSON::XS->new->utf8;

# ============================================
# Constructor
# ============================================
subtest 'constructor defaults' => sub {
    my $w = Purl::Alert::Webhook->new(
        name => 'test-wh',
        url  => 'https://example.com/alerts',
    );
    is $w->name, 'test-wh', 'name set';
    is $w->url, 'https://example.com/alerts', 'url set';
    is $w->method, 'POST', 'default method is POST';
    is $w->auth_token, '', 'default auth_token empty';
    is_deeply $w->headers, {}, 'default headers empty';
    ok !$w->has_signing_secret, 'no signing_secret by default';
};

subtest 'constructor with all options' => sub {
    my $w = Purl::Alert::Webhook->new(
        name           => 'full',
        url            => 'https://api.example.com/hook',
        method         => 'PUT',
        auth_token     => 'bearer-token-123',
        signing_secret => 'my-secret',
        headers        => { 'X-Custom' => 'value' },
    );
    is $w->method, 'PUT', 'PUT method';
    is $w->auth_token, 'bearer-token-123', 'auth token set';
    ok $w->has_signing_secret, 'has signing secret';
    is $w->headers->{'X-Custom'}, 'value', 'custom header set';
};

# ============================================
# deliver — POST success
# ============================================
subtest 'deliver POST success' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my ($captured_url, $captured_opts, $captured_method);

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_url = $url;
        $captured_opts = $opts;
        $captured_method = 'POST';
        return { success => 1, status => 200, content => 'ok' };
    });

    my $w = Purl::Alert::Webhook->new(
        name => 'test',
        url  => 'https://example.com/hook',
    );

    my $result = $w->deliver({
        alert     => 'Test Alert',
        severity  => 'warning',
        count     => 5,
        threshold => 3,
        window    => 5,
        time      => 'now',
    });

    ok $result, 'deliver succeeded';
    is $captured_url, 'https://example.com/hook', 'correct URL';
    is $captured_method, 'POST', 'used POST';
    like $captured_opts->{headers}{'Content-Type'}, qr/application\/json/, 'JSON content type';

    # Verify payload structure
    my $payload = $json->decode($captured_opts->{content});
    is $payload->{event}, 'purl.alert', 'event type set';
    ok $payload->{timestamp}, 'timestamp present';
    is ref $payload->{alert}, 'HASH', 'alert data is hash';
    is $payload->{alert}{alert}, 'Test Alert', 'alert name in payload';
};

# ============================================
# deliver — PUT method
# ============================================
subtest 'deliver PUT method' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $used_put = 0;

    $http_mock->redefine('put', sub {
        $used_put = 1;
        return { success => 1, status => 200 };
    });

    my $w = Purl::Alert::Webhook->new(
        name   => 'test',
        url    => 'https://example.com/hook',
        method => 'PUT',
    );

    $w->deliver({ alert => 'T', severity => 'warning', count => 1, threshold => 1, window => 5, time => 'now' });
    ok $used_put, 'PUT method used';
};

# ============================================
# deliver — unsupported method
# ============================================
subtest 'deliver unsupported method returns 0' => sub {
    my $w = Purl::Alert::Webhook->new(
        name   => 'test',
        url    => 'https://example.com/hook',
        method => 'DELETE',
    );

    my $result = $w->deliver({ alert => 'T', severity => 'w', count => 1, threshold => 1, window => 5, time => 'now' });
    ok !$result, 'unsupported method returns 0';
};

# ============================================
# deliver — with auth_token
# ============================================
subtest 'deliver includes Bearer auth header' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $captured_headers;

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_headers = $opts->{headers};
        return { success => 1, status => 200 };
    });

    my $w = Purl::Alert::Webhook->new(
        name       => 'test',
        url        => 'https://example.com/hook',
        auth_token => 'my-secret-token',
    );

    $w->deliver({ alert => 'T', severity => 'w', count => 1, threshold => 1, window => 5, time => 'now' });
    is $captured_headers->{Authorization}, 'Bearer my-secret-token', 'Bearer token in header';
};

# ============================================
# deliver — with signing_secret (HMAC)
# ============================================
subtest 'deliver includes HMAC signature' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my ($captured_headers, $captured_body);

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_headers = $opts->{headers};
        $captured_body = $opts->{content};
        return { success => 1, status => 200 };
    });

    my $secret = 'webhook-signing-secret';
    my $w = Purl::Alert::Webhook->new(
        name           => 'test',
        url            => 'https://example.com/hook',
        signing_secret => $secret,
    );

    $w->deliver({ alert => 'T', severity => 'w', count => 1, threshold => 1, window => 5, time => 'now' });

    ok exists $captured_headers->{'X-Purl-Signature'}, 'signature header present';
    my $sig = $captured_headers->{'X-Purl-Signature'};
    like $sig, qr/^sha256=[a-f0-9]{64}$/, 'sha256= prefix + hex signature';

    # Verify signature matches
    my $expected_sig = 'sha256=' . hmac_sha256_hex($captured_body, $secret);
    is $sig, $expected_sig, 'HMAC signature matches payload';
};

# ============================================
# deliver — with custom headers
# ============================================
subtest 'deliver merges custom headers' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $captured_headers;

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_headers = $opts->{headers};
        return { success => 1, status => 200 };
    });

    my $w = Purl::Alert::Webhook->new(
        name    => 'test',
        url     => 'https://example.com/hook',
        headers => { 'X-Source' => 'purl', 'X-Env' => 'prod' },
    );

    $w->deliver({ alert => 'T', severity => 'w', count => 1, threshold => 1, window => 5, time => 'now' });
    is $captured_headers->{'X-Source'}, 'purl', 'custom header X-Source';
    is $captured_headers->{'X-Env'}, 'prod', 'custom header X-Env';
    is $captured_headers->{'Content-Type'}, 'application/json', 'Content-Type preserved';
};

# ============================================
# deliver — HTTP failure
# ============================================
subtest 'deliver returns 0 on HTTP failure' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub {
        return { success => 0, status => 503, content => 'Service Unavailable' };
    });

    my $w = Purl::Alert::Webhook->new(
        name => 'test',
        url  => 'https://example.com/hook',
    );

    my $result = $w->deliver({ alert => 'T', severity => 'w', count => 1, threshold => 1, window => 5, time => 'now' });
    ok !$result, 'returns 0 on failure';
};

# ============================================
# send_test
# ============================================
subtest 'send_test sends test alert' => sub {
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    my $captured_body;

    $http_mock->redefine('post', sub {
        my ($self, $url, $opts) = @_;
        $captured_body = $opts->{content};
        return { success => 1, status => 200 };
    });

    my $w = Purl::Alert::Webhook->new(
        name => 'test',
        url  => 'https://example.com/hook',
    );

    my $result = $w->send_test;
    ok $result, 'send_test succeeded';

    my $payload = $json->decode($captured_body);
    is $payload->{alert}{alert}, 'Test Connection', 'test message alert name';
    is $payload->{alert}{severity}, 'warning', 'test message severity';
};

done_testing;

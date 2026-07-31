#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use Mojo::JSON qw(encode_json);

use PurlTest::Mock qw(mock_ctx mock_storage);
use Purl::Config;
use Purl::API::Controller::Settings;

# ============================================
# Every write-only secret needs an is-set flag in GET.
#
# A write-only secret is one GET never hands back — it reports 0/1 "is it
# set" instead. That flag is not cosmetic: it is the ONLY thing that tells
# the UI apart the two states it must render differently:
#
#   "there is no token"      -> offer nothing to remove
#   "there is a token you    -> offer to remove it
#    are not allowed to see"
#
# webhook.auth_token shipped without one. The clear-secret endpoint accepts
# clear_auth_token, but the UI could not honestly offer it, because a blank
# field is what a set-but-undisclosed token looks like. So the one secret
# most likely to need rotating was the one that could not be cleared.
#
# This pins a flag for EVERY write-only notification secret, not just the one
# that was missing — the gap existed because nothing asserted the set as a
# whole.
# ============================================

my $dir = tempdir(CLEANUP => 1);
my $seq = 0;

sub notifications_get {
    my ($seed) = @_;

    my $file = File::Spec->catfile($dir, 'settings-' . ++$seq . '.json');
    open my $fh, '>', $file or die "cannot write $file: $!";
    print $fh encode_json({ notifications => $seed });
    close $fh;

    my $ctrl = Purl::API::Controller::Settings->new(
        storage  => mock_storage(),
        settings => Purl::Config->new(config_file => $file),
    );

    my $c = mock_ctx(role => 'admin');
    $ctrl->get_all($c);

    my $rendered = $c->rendered
        or die 'get_all rendered nothing';
    return $rendered->{json}{notifications};
}

subtest 'every write-only notification secret reports whether it is set' => sub {
    my $set = notifications_get({
        telegram => { bot_token => 'tok', chat_id => '-100111' },
        slack    => { webhook_url => 'https://hooks.slack.test/x' },
        webhook  => { url => 'https://hook.test/x', auth_token => 'sekret' },
    });

    is $set->{telegram}{bot_token},   1, 'telegram.bot_token set';
    is $set->{telegram}{chat_id},     1, 'telegram.chat_id set';
    is $set->{slack}{webhook_set},    1, 'slack.webhook_url set';
    is $set->{webhook}{url_set},      1, 'webhook.url set';
    is $set->{webhook}{auth_token_set}, 1,
        'webhook.auth_token set — the flag that was missing';

    my $unset = notifications_get({
        telegram => {},
        slack    => {},
        webhook  => { url => 'https://hook.test/x' },
    });

    is $unset->{telegram}{bot_token},     0, 'telegram.bot_token unset';
    is $unset->{telegram}{chat_id},       0, 'telegram.chat_id unset';
    is $unset->{slack}{webhook_set},      0, 'slack.webhook_url unset';
    is $unset->{webhook}{url_set},        1, 'webhook.url still set';
    is $unset->{webhook}{auth_token_set}, 0,
        'webhook.auth_token unset while url is set — the two must not share a flag';
};

subtest 'the value itself is never disclosed' => sub {
    my $got = notifications_get({
        telegram => { bot_token => 'tok-SECRET' },
        slack    => { webhook_url => 'https://hooks.slack.test/SECRET' },
        webhook  => { url => 'https://hook.test/x', auth_token => 'auth-SECRET' },
    });

    my $json = encode_json($got);
    unlike $json, qr/SECRET/,
        'no write-only secret value appears anywhere in the notifications payload';
};

done_testing();

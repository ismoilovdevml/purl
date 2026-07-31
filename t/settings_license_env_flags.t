#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

use PurlTest::Mock qw(mock_ctx mock_storage);

use Purl::Config;
use Purl::API::Controller::Settings;

# ============================================
# REGRESSION (#72): the license panel must be TOLD that PURL_LICENSE_KEY owns
# the key, before the admin types into it.
#
# update_license already refuses an env-owned key with 409 (pinned by
# t/settings_env_shadow.t). But no GET reported the license section's env state
# at all, so the UI had nothing to read: the input rendered editable and the
# admin discovered the lock only by pasting a key and being refused on save.
# That is #66 exactly — guard on the write side, silence on the read side.
#
# Shape matters as much as content. The older per-field `{ value, from_env }`
# spelling (clickhouse/retention/auth above) is what hid #66 from review: a
# grep for `from_env_keys` did not find it. So the license section reports the
# per-key map — one spelling, greppable, and derived from %ENV_MAP via
# Controller::Base::env_flags so a new license.* mapping shows up for free.
# ============================================

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

sub fresh_settings {
    unlink $file;
    local $ENV{PURL_CONFIG_FILE} = $file;
    return Purl::Config->new(config_file => $file);
}

sub license_section {
    my ($settings) = @_;
    my $ctrl = Purl::API::Controller::Settings->new(
        storage  => mock_storage(),
        settings => $settings,
    );
    my $c = mock_ctx();
    $ctrl->get_all($c);
    return $c->rendered->{json}{license};
}

subtest 'the settings GET reports a license section at all' => sub {
    my $settings = fresh_settings();
    my $license  = license_section($settings);

    ok defined $license, 'GET /api/settings carries a license section';
    is ref $license->{from_env_keys}, 'HASH',
        'and it carries the per-key env map the UI reads';
};

subtest 'PURL_LICENSE_KEY is reported as locked' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'env-owned-license-key';

    my $settings = fresh_settings();
    my $license  = license_section($settings);

    is $license->{from_env_keys}{key}, 1,
        'license.key reported locked while the environment owns it';
};

subtest 'an unset variable reports 0, not a missing key' => sub {
    delete local $ENV{PURL_LICENSE_KEY};

    my $settings = fresh_settings();
    my $license  = license_section($settings);

    ok exists $license->{from_env_keys}{key}, 'the key is still reported';
    is $license->{from_env_keys}{key}, 0, 'as unlocked';
};

subtest 'every env-mappable license key is reported, not a subset' => sub {
    # The anti-drift assertion: the response is built from %ENV_MAP, so adding
    # a license.* mapping cannot leave a field editable that ENV owns.
    my $settings = fresh_settings();
    my $license  = license_section($settings);

    my @reported = sort keys %{ $license->{from_env_keys} };
    my @mappable = $settings->env_managed_keys('license');

    cmp_ok scalar(@mappable), '>', 1, 'license has more than one mappable key';
    is_deeply \@reported, \@mappable,
        'all ' . scalar(@mappable) . ' env-mappable license keys are reported';
};

subtest 'the license env state uses from_env_keys, not per-field {value, from_env}' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'env-owned-license-key';

    my $settings = fresh_settings();
    my $license  = license_section($settings);

    ok !exists $license->{key},
        'no per-field license.key wrapper — one spelling for env state';
    ok !grep({ ref $license->{$_} eq 'HASH' && exists $license->{$_}{from_env} }
             keys %$license),
        'no field carries the old scalar from_env spelling';
};

subtest 'the GET never discloses the stored license key' => sub {
    delete local $ENV{PURL_LICENSE_KEY};

    my $settings = fresh_settings();
    $settings->set('license', 'key', 'super-secret-jwt-license');

    my $license = license_section($settings);

    unlike encode_json($license), qr/super-secret-jwt-license/,
        'the key itself stays server-side; only its lock state is published';
};

done_testing;

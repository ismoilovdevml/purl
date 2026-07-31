#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use JSON::XS;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Config;

# ============================================
# REGRESSION (#45): a section write must never persist an ENV-provided value.
#
# get_section() resolves ENV over file. update_section()/set_section() then
# wrote the merged result straight back, so every edit to any key in a section
# baked the environment's values for the OTHER keys into settings.json:
#
#   PURL_API_KEYS='envkey1,envkey2'  +  any auth edit
#     -> settings.json: "api_keys": "envkey1,envkey2"
#
# Two consequences, both on the default Helm path (the chart always sets
# PURL_API_KEYS, PURL_CLICKHOUSE_PASSWORD, ...):
#
#   1. the secret is copied out of the Kubernetes Secret onto the config PVC in
#      plaintext, and that PVC is annotated resource-policy: keep, so it
#      outlives `helm uninstall`;
#   2. ENV still wins on READ, so an edit to such a key is a no-op that reports
#      success — a revoked API key kept authenticating.
# ============================================

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

sub fresh_config {
    local $ENV{PURL_CONFIG_FILE} = $file;
    return Purl::Config->new(config_file => $file);
}

sub on_disk {
    open my $fh, '<:encoding(UTF-8)', $file or die "cannot read $file: $!";
    local $/;
    my $json = <$fh>;
    close $fh;
    return JSON::XS->new->decode($json);
}

sub reset_file {
    unlink $file;
    return;
}

# ============================================
# Secrets never reach the file
# ============================================

subtest 'update_section does not write the ENV API keys to disk' => sub {
    reset_file();
    local $ENV{PURL_API_KEYS}     = 'envkey1,envkey2';
    local $ENV{PURL_AUTH_ENABLED} = 1;

    my $cfg = fresh_config();
    $cfg->update_section('auth', sub {
        my ($auth) = @_;
        $auth->{users} = { admin => 'hash-admin' };
    });

    my $disk = on_disk();
    ok !exists $disk->{auth}{api_keys},
        'the env API keys were not persisted';
    is_deeply $disk->{auth}{users}, { admin => 'hash-admin' },
        'the key we actually edited was';

    my $raw = JSON::XS->new->encode($disk);
    unlike $raw, qr/envkey/, 'no fragment of the secret anywhere in the file';
};

subtest 'set_section does not write ENV secrets to disk either' => sub {
    reset_file();
    local $ENV{PURL_CLICKHOUSE_PASSWORD} = 'ch-secret';
    local $ENV{PURL_CLICKHOUSE_HOST}     = 'clickhouse.internal';

    # The exact shape Settings::update_clickhouse uses: read the merged
    # section, change one field, write the whole thing back.
    my $cfg = fresh_config();
    my $current = $cfg->get_section('clickhouse');
    is $current->{password}, 'ch-secret', 'the merged read does see the env value';
    $current->{database} = 'purl_new';
    $cfg->set_section('clickhouse', $current);

    my $disk = on_disk();
    is $disk->{clickhouse}{database}, 'purl_new', 'the edited field was saved';
    ok !exists $disk->{clickhouse}{password}, 'the env password was not';
    ok !exists $disk->{clickhouse}{host},     'nor the env host';
};

subtest 'every ENV-backed secret in a section is stripped, not just the first' => sub {
    reset_file();
    local $ENV{PURL_LDAP_BIND_PASSWORD} = 'ldap-pw';
    local $ENV{PURL_LDAP_BIND_DN}       = 'cn=svc,dc=example,dc=com';
    local $ENV{PURL_LDAP_SERVER}        = 'ldap.example.com';

    my $cfg = fresh_config();
    $cfg->update_section('ldap', sub { $_[0]->{search_base} = 'dc=example,dc=com' });

    my $raw = JSON::XS->new->encode(on_disk());
    unlike $raw, qr/ldap-pw/,          'bind password not persisted';
    unlike $raw, qr/cn=svc/,           'bind DN not persisted';
    unlike $raw, qr/ldap\.example\.com/, 'server not persisted';
    is on_disk()->{ldap}{search_base}, 'dc=example,dc=com', 'the edit landed';
};

# ============================================
# An existing FILE value under an ENV shadow is preserved, not deleted
# ============================================

subtest 'a file value shadowed by ENV survives an unrelated edit' => sub {
    reset_file();

    # Written while no env var is set — a genuine on-disk key list.
    {
        my $cfg = fresh_config();
        $cfg->update_section('auth', sub {
            $_[0]->{api_keys} = [ { key => 'filekey1', label => 'ci' } ];
        });
    }
    is_deeply on_disk()->{auth}{api_keys}, [ { key => 'filekey1', label => 'ci' } ],
        'stored while unshadowed';

    # Now the env takes over and something else in the section is edited.
    {
        local $ENV{PURL_API_KEYS} = 'envkey1';
        my $cfg = fresh_config();
        $cfg->update_section('auth', sub { $_[0]->{users} = { admin => 'h' } });
    }

    is_deeply on_disk()->{auth}{api_keys}, [ { key => 'filekey1', label => 'ci' } ],
        'the file value is untouched — neither overwritten by the env value nor dropped';
};

# ============================================
# The read side stays exactly as it was
# ============================================

subtest 'ENV still wins on read; only the WRITE path changed' => sub {
    reset_file();
    local $ENV{PURL_API_KEYS} = 'envkey1,envkey2';

    my $cfg = fresh_config();
    $cfg->update_section('auth', sub { $_[0]->{users} = { admin => 'h' } });

    is $cfg->get_section('auth')->{api_keys}, 'envkey1,envkey2',
        'the running process still authenticates with the env keys';
    ok $cfg->is_from_env('auth', 'api_keys'), 'and still reports them as env-managed';
};

# ============================================
# update_section can decline to write at all
# ============================================

subtest 'a cancelled update_section leaves the file byte-identical' => sub {
    reset_file();
    my $cfg = fresh_config();
    $cfg->update_section('auth', sub { $_[0]->{users} = { admin => 'h' } });

    my @before = stat $file;
    sleep 1;    # make a rewrite observable in mtime

    my $result = $cfg->update_section('auth', sub {
        my ($auth, $cancel) = @_;
        $auth->{users} = { admin => 'WRECKED' };
        return $cancel->();
    });

    ok !$result, 'a cancelled update reports failure, not success';
    my @after = stat $file;
    is $after[9], $before[9], 'the file was not rewritten';
    is_deeply on_disk()->{auth}{users}, { admin => 'h' },
        'and the mutation the callback made was discarded';
};

done_testing();

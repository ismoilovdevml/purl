#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Config;
use Purl::API::Controller::Settings;

# ============================================
# REGRESSION (#45): the API-key endpoints must not pretend.
#
# PURL_API_KEYS wins on every read, so while it is set NOTHING done through
# these endpoints can take effect: a generated key is written to settings.json
# and never authenticates, a revoked key keeps working and keeps showing up in
# the list. Refusing with 409 (well-formed request, resource owned by the
# environment) is the only honest answer.
#
# Also pinned here: a revoke that matches nothing must not rewrite the file.
# ============================================

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

{
    package MockCtx;
    sub new {
        my ($class, %args) = @_;
        return bless {
            body     => $args{body} // '',
            params   => $args{params} // {},
            rendered => undef,
        }, $class;
    }
    sub req  { $_[0] }
    sub body { $_[0]->{body} }
    sub app  { $_[0] }
    sub log  { $_[0] }
    sub error { }
    sub param { $_[0]->{params}{$_[1]} }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub stash { return undef }
    sub session { my ($s, $k) = @_; my %h = (role => 'admin'); return defined $k ? $h{$k} : \%h }
}

sub controller {
    local $ENV{PURL_CONFIG_FILE} = $file;
    my $settings = Purl::Config->new(config_file => $file);
    my $ctrl = Purl::API::Controller::Settings->new(
        storage  => bless({}, 'MockStorage'),
        settings => $settings,
    );
    return ($ctrl, $settings);
}

sub seed_file_keys {
    unlink $file;
    local $ENV{PURL_CONFIG_FILE} = $file;
    my $cfg = Purl::Config->new(config_file => $file);
    $cfg->update_section('auth', sub {
        $_[0]->{api_keys} = [
            { key => 'filekey1abcdefghijklmnop', label => 'ci',  created_at => '' },
            { key => 'filekey2abcdefghijklmnop', label => 'app', created_at => '' },
        ];
    });
    return;
}

subtest 'generate refuses with 409 while PURL_API_KEYS owns the list' => sub {
    seed_file_keys();
    local $ENV{PURL_API_KEYS} = 'envkey1,envkey2';

    my ($ctrl) = controller();
    my $c = MockCtx->new(body => encode_json({ label => 'new' }));
    $ctrl->generate_api_key($c);

    is $c->rendered->{status}, 409,
        'conflict, not 200 — a key minted here could never authenticate';
    is $c->rendered->{json}{from_env}, 1, 'and says who owns the list';
    ok !exists $c->rendered->{json}{api_key}, 'no key was handed out';
};

subtest 'revoke refuses with 409 while PURL_API_KEYS owns the list' => sub {
    seed_file_keys();
    local $ENV{PURL_API_KEYS} = 'envkey1,envkey2';

    my ($ctrl) = controller();
    my $c = MockCtx->new(params => { key_id => 'filekey1' });
    $ctrl->revoke_api_key($c);

    is $c->rendered->{status}, 409,
        'conflict, not a success message for a revocation that cannot work';
};

subtest 'without the env var the endpoints work normally' => sub {
    seed_file_keys();
    delete local $ENV{PURL_API_KEYS};

    my ($ctrl, $settings) = controller();
    my $c = MockCtx->new(params => { key_id => 'filekey1' });
    $ctrl->revoke_api_key($c);

    is $c->rendered->{json}{status}, 'ok', 'revoked';
    my $remaining = $settings->get_section('auth')->{api_keys};
    is scalar @$remaining, 1, 'one key left';
    is $remaining->[0]{key}, 'filekey2abcdefghijklmnop', 'the right one';
};

subtest 'a revoke that matches nothing 404s WITHOUT rewriting the file' => sub {
    seed_file_keys();
    delete local $ENV{PURL_API_KEYS};

    my @before = stat $file;
    sleep 1;    # make a rewrite observable in mtime

    my ($ctrl, $settings) = controller();
    my $c = MockCtx->new(params => { key_id => 'nosuchkey' });
    $ctrl->revoke_api_key($c);

    is $c->rendered->{status}, 404, 'reported as not found';
    my @after = stat $file;
    is $after[9], $before[9], 'and settings.json was left alone';
    is scalar @{ $settings->get_section('auth')->{api_keys} }, 2,
        'both keys still there';
};

done_testing();

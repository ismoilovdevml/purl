#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ============================================
# REGRESSION (#37): the prefork config reload must reach the auth gate.
#
# Server.pm hands the auth middleware `config => $config`, a plain hashref
# assembled BEFORE fork() from Purl::Config::get_section — and get_section
# returns a COPY, not a live reference. check_auth read `$self->config->{auth}`
# from that copy, so:
#
#   * a worker's snapshot of the auth section is frozen at fork time;
#   * an API key or user added through the UI is written by ONE worker;
#   * every other worker rejects it until the process restarts.
#
# Purl::Config re-reads settings.json whenever its stat stamp moves, so reading
# the section THROUGH the config object is what carries the change across
# workers. This is the same defect as #18, left open for a different credential
# type.
#
# Revert _auth_config to `$self->config->{auth} // {}` and the two "after
# another worker wrote" subtests below fail.
# ============================================

BEGIN {
    # The ENV key list short-circuits _check_api_key; this file is about the
    # keys that live in settings.json.
    delete $ENV{PURL_API_KEYS};
    delete $ENV{PURL_AUTH_ENABLED};
}

use Purl::Config;
use Purl::API::Middleware::Auth;

# Minimal controller stand-in: headers, session, stash.
{
    package MockHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{ $_[1] } }
    sub authorization { $_[0]->{h}{Authorization} }

    package MockReq;
    sub new { bless { headers => MockHeaders->new($_[1]) }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new { bless { req => MockReq->new($_[1]), stash => {}, session => {} }, $_[0] }
    sub req { $_[0]->{req} }
    sub session { $_[0]->{session} }
    sub stash {
        my ($self, $k, $v) = @_;
        return $self->{stash} unless defined $k;
        $self->{stash}{$k} = $v if defined $v;
        return $self->{stash}{$k};
    }
}

my $dir  = tempdir(CLEANUP => 1);
my $file = File::Spec->catfile($dir, 'settings.json');

# The revision that existed at fork time.
my $bootstrap = Purl::Config->new(config_file => $file);
$bootstrap->set_section('auth', {
    enabled  => 1,
    users    => {},
    api_keys => [ { key => 'key-from-boot', label => 'boot' } ],
});

# What Server.pm passes to the middleware: a COPY taken before fork().
my $prefork_snapshot = { auth => $bootstrap->get_section('auth') };

sub worker_middleware {
    my $mw = Purl::API::Middleware::Auth->new(config => $prefork_snapshot);
    # Server.pm wires this immediately after construction.
    $mw->settings(Purl::Config->new(config_file => $file));
    return $mw;
}

sub check_key {
    my ($mw, $key) = @_;
    return $mw->check_auth(MockCtrl->new({ 'X-API-Key' => $key })) ? 1 : 0;
}

# ============================================

subtest 'auth is enabled and anonymous access is refused' => sub {
    my $mw = worker_middleware();
    is $mw->auth_enabled, 1, 'auth enabled comes from settings.json';
    is $mw->check_auth(MockCtrl->new({})) ? 1 : 0, 0, 'no credentials => refused';
};

subtest 'the pre-fork key still works' => sub {
    my $mw = worker_middleware();
    is check_key($mw, 'key-from-boot'), 1, 'key present at fork time is accepted';
    is check_key($mw, 'never-issued'),  0, 'a bogus key is still refused';
};

subtest 'an API key added by another worker is accepted here' => sub {
    my $mw = worker_middleware();
    is check_key($mw, 'key-from-ui'), 0, 'not valid yet';

    # Another worker handles POST /api/settings/api-keys and writes the file.
    Purl::Config->new(config_file => $file)->update_section('auth', sub {
        push @{ $_[0]{api_keys} }, { key => 'key-from-ui', label => 'added via UI' };
    });

    is check_key($mw, 'key-from-ui'), 1,
        'this worker accepts the new key without a restart';
    is check_key($mw, 'key-from-boot'), 1, 'and the original key still works';
};

subtest 'an API key revoked by another worker is refused here' => sub {
    my $mw = worker_middleware();
    is check_key($mw, 'key-from-boot'), 1, 'valid before revocation';

    Purl::Config->new(config_file => $file)->update_section('auth', sub {
        $_[0]{api_keys} = [ grep { $_->{key} ne 'key-from-boot' } @{ $_[0]{api_keys} } ];
    });

    is check_key($mw, 'key-from-boot'), 0,
        'a revoked key stops working on every worker, not just the writer';
};

subtest 'a user added by another worker can use basic auth here' => sub {
    my $mw = worker_middleware();
    my $hash = $mw->hash_password('S3cretPassw0rd');

    require MIME::Base64;
    my $header = 'Basic ' . MIME::Base64::encode_base64('newbie:S3cretPassw0rd', '');

    is $mw->check_auth(MockCtrl->new({ Authorization => $header })) ? 1 : 0, 0,
        'unknown user refused';

    Purl::Config->new(config_file => $file)->update_section('auth', sub {
        $_[0]{users}{newbie} = { password => $hash, role => 'viewer' };
    });

    is $mw->check_auth(MockCtrl->new({ Authorization => $header })) ? 1 : 0, 1,
        'the freshly created user authenticates on this worker too';
};

subtest 'disabling auth elsewhere opens this worker' => sub {
    my $mw = worker_middleware();
    is $mw->auth_enabled, 1, 'enabled to start with';

    Purl::Config->new(config_file => $file)->update_section('auth', sub {
        $_[0]{enabled} = 0;
    });

    is $mw->auth_enabled, 0, 'the flag is re-read, not frozen at fork time';
    is $mw->check_auth(MockCtrl->new({})) ? 1 : 0, 1, 'and the gate opens';
};

subtest 'without a settings object the pre-fork snapshot is still honoured' => sub {
    # Embedded/test wiring that never calls ->settings must keep working.
    my $mw = Purl::API::Middleware::Auth->new(
        config => { auth => { enabled => 1, api_keys => ['standalone-key'] } },
    );
    is check_key($mw, 'standalone-key'), 1, 'plain-string key entry accepted';
    is check_key($mw, 'other'), 0, 'and anything else refused';
};

subtest 'a comma-separated api_keys string is not mistaken for an arrayref' => sub {
    # get_section resolves ENV over file, so PURL_API_KEYS arrives here as a
    # raw string. Dereferencing it was a 500 on every authenticated request.
    my $mw = Purl::API::Middleware::Auth->new(
        config => { auth => { enabled => 1, api_keys => 'a-key,b-key' } },
    );
    is check_key($mw, 'b-key'), 1, 'the string is split into keys';
    is check_key($mw, 'c-key'), 0, 'and a non-member is refused';
};

done_testing();

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

# ============================================
# REGRESSION (#101): the audit log never recorded anything.
#
# The audit_event helper (Server/Hooks.pm) wrote through $c->app->storage, a
# helper the server never registered, so every write died inside the helper's
# eval and Settings > Audit Logs stayed empty. Tests passed only because the
# harness registered its own `storage` helper.
#
# This boots the REAL app (PurlTest::SessionApp adds no helper) on a recording
# storage and asserts the rows the dashboard's audit page is built on. It also
# pins the prefork/rebuild boundary: after a settings change swaps storage,
# audit rows go to the NEW storage, never a stale captured one.
# ============================================

use PurlTest::SessionApp qw(app storage login csrf admin_call with_csrf);
use PurlTest::Mock qw(mock_server_storage);
use Test::Mojo;

my $ADMIN_PW = 'StrongAdminPass123';

ok !app()->renderer->helpers->{storage}, 'no test-only storage helper is in play';

# Events recorded on $st by $code, in order.
sub recorded {
    my ($code, $st) = @_;
    $st //= storage();
    my $n = @{ $st->audit_events };
    $code->();
    my @all = @{ $st->audit_events };
    return [ @all[$n .. $#all] ];
}

sub one {
    my ($events, $action) = @_;
    my @hit = grep { $_->{action} eq $action } @$events;
    is scalar(@hit), 1, "exactly one '$action' row" or diag explain $events;
    return $hit[0] // {};
}

subtest 'login: success and failure' => sub {
    my $ev = one(recorded(sub { login('admin', $ADMIN_PW) }), 'login');
    is $ev->{status}, 'success', 'status';
    is $ev->{actor},  'admin',   'actor';
    ok length $ev->{ip_address}, 'client ip recorded';

    $ev = one(recorded(sub {
        Test::Mojo->new(app())->post_ok('/api/auth/login',
            json => { username => 'admin', password => 'wrong-password' })->status_is(401);
    }), 'login');
    is $ev->{status}, 'failure', 'failed login is a failure row';
    is $ev->{actor},  'admin',   'for the name that was tried';
};

subtest 'logout' => sub {
    my $t  = login('admin', $ADMIN_PW);
    my $ev = one(recorded(sub { $t->post_ok('/api/auth/logout', with_csrf())->status_is(200) }), 'logout');
    is $ev->{status}, 'success', 'status';
    is $ev->{actor},  'admin',   'actor';
};

subtest 'settings change' => sub {
    my $ev = one(recorded(sub {
        admin_call(put => '/api/settings/retention', { days => 30 });
    }), 'update_settings');
    is $ev->{resource_type}, 'settings',  'resource_type';
    is $ev->{resource_id},   'retention', 'resource_id names the section';
    is $ev->{actor},         'admin',     'actor';

    # A refused change is not recorded as one.
    my $events = recorded(sub { admin_call(put => '/api/settings/retention', { days => 9999 }, 400) });
    ok !(grep { $_->{action} eq 'update_settings' } @$events), 'rejected change: no row';
};

subtest 'user management' => sub {
    my $ev = one(recorded(sub {
        admin_call(post => '/api/settings/users',
            { username => 'dave', password => 'DavePass12345', role => 'viewer' });
    }), 'create_user');
    is $ev->{resource_type}, 'user', 'resource_type';
    is $ev->{resource_id},   'dave', 'resource_id';
    is $ev->{actor},         'admin', 'actor is the admin, not the new user';

    $ev = one(recorded(sub { admin_call(put => '/api/settings/users/dave', { role => 'operator' }) }),
        'update_user');
    is $ev->{resource_id}, 'dave', 'update_user: resource_id';

    $ev = one(recorded(sub { admin_call(delete => '/api/settings/users/dave') }), 'delete_user');
    is $ev->{resource_id}, 'dave', 'delete_user: resource_id';

    my $events = recorded(sub { admin_call(delete => '/api/settings/users/nobody', undef, 404) });
    ok !(grep { $_->{action} eq 'delete_user' } @$events), 'refused delete: no row';
};

subtest 'api keys' => sub {
    my $t;
    my $ev = one(recorded(sub { $t = admin_call(post => '/api/settings/api-keys', { label => 'ci' }) }),
        'generate_api_key');
    my $key    = $t->tx->res->json->{api_key};
    my $key_id = substr($key, 0, 8);
    is $ev->{resource_type}, 'api_key', 'resource_type';
    is $ev->{resource_id},   $key_id,   'resource_id is the listing id';
    unlike join(' ', map { $_ // '' } values %$ev), qr/\Q$key\E/, 'the key itself is never recorded';

    $ev = one(recorded(sub { admin_call(delete => "/api/settings/api-keys/$key_id") }),
        'revoke_api_key');
    is $ev->{resource_id}, $key_id, 'revoke: resource_id';
};

subtest 'logout whose revocation was not persisted' => sub {
    my $t = login('admin', $ADMIN_PW);
    my $events = recorded(sub {
        no warnings 'redefine';
        local *Purl::Config::save = sub { $_[0]{_last_save_error} = 'disk full'; return 0 };
        $t->post_ok('/api/auth/logout', with_csrf())->status_is(500);
    });
    my $ev = one($events, 'logout');
    is $ev->{status},  'failure', 'audited as a failure';
    is $ev->{actor},   'admin',   'with the user it concerns';
    like $ev->{details}, qr/not persisted/, 'and why';
};

subtest 'after storage is rebuilt, audit rows go to the CURRENT storage' => sub {
    my $old = storage();
    my $new = mock_server_storage();
    no warnings 'redefine';
    local *Purl::API::Server::_build_storage = sub { return $new };

    # update_clickhouse calls rebuild_storage; database is not env-managed here.
    admin_call(put => '/api/settings/clickhouse', { database => 'purl_audit_test' });

    my $stale = recorded(sub {
        my $fresh = recorded(sub { login('admin', $ADMIN_PW) }, $new);
        is one($fresh, 'login')->{status}, 'success', 'the login after the rebuild is on the new storage';
    }, $old);
    ok !(grep { $_->{action} eq 'login' } @$stale), 'and not on the replaced one';
};

done_testing;

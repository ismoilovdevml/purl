#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# Regression: "-1 means unlimited" must be honoured by EVERY quota check.
#
# The bug: Controller::Settings open-coded `scalar(keys %$users) >= $max_users`
# instead of calling Controller::Base::check_limit. With the unlimited
# sentinel -1 that reads `0 >= -1`, which is TRUE — so a plan advertising
# unlimited users could not create a single one ("User limit reached (-1)").
#
# These tests pin the sentinel semantics at the one gate everybody must use,
# and at the two call sites that used to bypass it.
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Base;
use Purl::API::Controller::Settings;
use Purl::API::Controller::Logs;

{
    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReq;
    sub new     { bless { body => $_[1] // '' }, $_[0] }
    sub body    { $_[0]->{body} }
    sub headers { MockReqHeaders->new }

    package MockReqHeaders;
    sub new              { bless {}, $_[0] }
    sub content_encoding { undef }

    package MockCtrl;
    sub new {
        my ($class, $body, $stash) = @_;
        bless {
            req      => MockReq->new($body),
            rendered => undef,
            stash    => $stash // {},
            app      => MockApp->new,
        }, $class;
    }
    sub req      { $_[0]->{req} }
    sub app      { $_[0]->{app} }
    sub param    { undef }
    sub render   { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($s, $k, $v) = @_;
        return $s->{stash} unless defined $k;
        $s->{stash}{$k} = $v if defined $v;
        return $s->{stash}{$k};
    }
    sub session { my $s = { role => 'admin' }; defined $_[1] ? $s->{$_[1]} : $s }

    package MockStorage;
    sub new { bless {}, $_[0] }
}

my $base = Purl::API::Controller::Base->new(storage => MockStorage->new);

# ---------------------------------------------------------------------------
# check_limit sentinel semantics
# ---------------------------------------------------------------------------
subtest 'check_limit treats -1 as unlimited' => sub {
    for my $count (0, 1, 100, 100_000) {
        my $c = MockCtrl->new(undef, { license_info => { limits => { users => -1 } } });
        ok $base->check_limit($c, 'users', $count), "count=$count allowed under -1";
        is $c->rendered, undef, 'nothing rendered when the quota is unlimited';
    }
};

subtest 'check_limit enforces a finite quota' => sub {
    my $c = MockCtrl->new(undef, { license_info => { plan => 'legacy', limits => { users => 3 } } });
    ok $base->check_limit($c, 'users', 2), '2 of 3 used — one more allowed';

    $c = MockCtrl->new(undef, { license_info => { plan => 'legacy', limits => { users => 3 } } });
    ok !$base->check_limit($c, 'users', 3), '3 of 3 used — blocked';
    is $c->rendered->{status}, 403, 'blocked with 403';
    like $c->rendered->{json}{error}, qr/Limit reached: users/, 'names the limit';
};

subtest 'check_limit honours the adding count' => sub {
    my $c = MockCtrl->new(undef, { license_info => { limits => { servers => 10 } } });
    ok $base->check_limit($c, 'servers', 8, 2), 'adding 2 to 8 fits exactly in 10';

    $c = MockCtrl->new(undef, { license_info => { limits => { servers => 10 } } });
    ok !$base->check_limit($c, 'servers', 8, 3), 'adding 3 to 8 exceeds 10';

    $c = MockCtrl->new(undef, { license_info => { limits => { servers => 10 } } });
    ok $base->check_limit($c, 'servers', 10, 0), 'adding nothing never fails';
};

subtest 'check_limit passes when the resource is not metered' => sub {
    my $c = MockCtrl->new(undef, {});
    ok $base->check_limit($c, 'users', 500), 'no license context = allowed';

    $c = MockCtrl->new(undef, { license_info => { limits => {} } });
    ok $base->check_limit($c, 'users', 500), 'limit absent from plan = not metered';
};

# ---------------------------------------------------------------------------
# Settings::create_user — the reported blocker
# ---------------------------------------------------------------------------
{
    package MockAuthMw;
    sub new { bless {}, $_[0] }
    sub hash_password { return 'hashed:' . $_[1] }

    package MockSettings;
    sub new { bless { _config => { auth => { users => $_[1] // {} } }, saved => 0 }, $_[0] }
    sub _config { $_[0]->{_config} }
    sub save    { $_[0]->{saved}++; 1 }
}

sub _settings_ctrl {
    my ($users) = @_;
    return Purl::API::Controller::Settings->new(
        storage         => MockStorage->new,
        settings        => MockSettings->new($users),
        auth_middleware => MockAuthMw->new,
    );
}

subtest 'create_user works when the plan grants unlimited users' => sub {
    my $ctrl = _settings_ctrl({ admin => { password => 'x', role => 'admin' } });
    my $c = MockCtrl->new(
        encode_json({ username => 'alice', password => 'longenough1' }),
        { license_info => { plan => 'free', limits => { users => -1 } } },
    );

    $ctrl->create_user($c);
    is $c->rendered->{json}{status}, 'ok',
        'user created under an unlimited (-1) quota (was: "User limit reached (-1)")';
    is $c->rendered->{json}{username}, 'alice', 'returns the new username';
};

subtest 'create_user still enforces a finite user quota' => sub {
    my $ctrl = _settings_ctrl({ admin => {}, bob => {} });
    my $c = MockCtrl->new(
        encode_json({ username => 'carol', password => 'longenough1' }),
        { license_info => { plan => 'legacy', limits => { users => 2 } } },
    );

    $ctrl->create_user($c);
    is $c->rendered->{status}, 403, 'over quota returns 403';
    like $c->rendered->{json}{error}, qr/Limit reached: users/, 'uses the shared gate message';
};

subtest 'create_user rejects a duplicate before touching the quota' => sub {
    my $ctrl = _settings_ctrl({ admin => {} });
    my $c = MockCtrl->new(
        encode_json({ username => 'admin', password => 'longenough1' }),
        { license_info => { plan => 'free', limits => { users => -1 } } },
    );

    $ctrl->create_user($c);
    is $c->rendered->{status}, 409, 'duplicate username still 409';
};

# ---------------------------------------------------------------------------
# Logs::ingest — server quota goes through the same gate
# ---------------------------------------------------------------------------
{
    package MockLogsStorage;
    sub new { bless { services => $_[1] // [], inserted => [] }, $_[0] }
    sub field_stats { return $_[0]->{services} }
    sub insert      { push @{ $_[0]->{inserted} }, $_[1]; 1 }
}

sub _ingest_ctx {
    my ($service, $limits) = @_;
    return MockCtrl->new(
        encode_json([{ message => 'hi', service => $service }]),
        { license_info => {
            valid => 1, activated => 1, plan => 'legacy', limits => $limits,
        } },
    );
}

subtest 'ingest is not blocked by an unlimited server quota' => sub {
    my $storage = MockLogsStorage->new([map { { value => "svc$_" } } 1 .. 20]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = _ingest_ctx('brand-new', { servers => -1 });

    $ctrl->ingest($c);
    isnt $c->rendered->{status}, 403, 'unlimited servers never 403s ingest';
    is scalar @{$storage->{inserted}}, 1, 'the log was actually stored';
};

subtest 'ingest enforces a finite server quota' => sub {
    my $storage = MockLogsStorage->new([{ value => 'svc1' }, { value => 'svc2' }]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = _ingest_ctx('svc3', { servers => 2 });

    $ctrl->ingest($c);
    is $c->rendered->{status}, 403, 'a third distinct service exceeds a 2-server plan';
    like $c->rendered->{json}{error}, qr/Limit reached: servers/, 'uses the shared gate message';
    is scalar @{$storage->{inserted}}, 0, 'nothing stored when over quota';
};

subtest 'ingest allows already-known services at the quota ceiling' => sub {
    my $storage = MockLogsStorage->new([{ value => 'svc1' }, { value => 'svc2' }]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = _ingest_ctx('svc2', { servers => 2 });

    $ctrl->ingest($c);
    isnt $c->rendered->{status}, 403, 'no new server added — ingest proceeds at the ceiling';
    is scalar @{$storage->{inserted}}, 1, 'the log was stored';
};

done_testing();

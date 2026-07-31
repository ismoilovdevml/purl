#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::Base;

# ============================================
# Mock Mojo controller
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockMojoCtrl;
    sub new {
        bless {
            stash    => $_[1] // {},
            rendered => undef,
            session  => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub app { $_[0]->{app} }
    sub rendered { $_[0]->{rendered} }
}

# Mock storage
{
    package MockStorage;
    sub new { bless {}, $_[0] }
}

# ============================================
# Constructor
# ============================================
subtest 'constructor with required storage' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    ok $ctrl, 'controller created';
    is ref $ctrl->storage, 'MockStorage', 'storage set';
    is_deeply $ctrl->config, {}, 'default config is empty hash';
    is_deeply $ctrl->cache, {}, 'default cache is empty hash';
};

# ============================================
# Caching (get_cached / set_cached)
# ============================================
subtest 'set_cached and get_cached' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    $ctrl->set_cached('key1', { data => 42 });
    is_deeply $ctrl->get_cached('key1'), { data => 42 }, 'cached value retrieved';
};

subtest 'get_cached returns undef for missing key' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    is $ctrl->get_cached('missing'), undef, 'missing key returns undef';
};

subtest 'get_cached returns undef for expired entry' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    $ctrl->set_cached('expire_key', 'value', 0);  # 0-second TTL
    sleep 1;
    is $ctrl->get_cached('expire_key'), undef, 'expired entry returns undef';
};

subtest 'set_cached default TTL is 60s' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    $ctrl->set_cached('ttl_key', 'val');
    my $entry = $ctrl->cache->{ttl_key};
    ok $entry->{expires} > time(), 'expires in the future';
    ok $entry->{expires} <= time() + 61, 'expires within ~60 seconds';
};

subtest 'set_cached custom TTL' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $ret = $ctrl->set_cached('custom', 'val', 300);
    is $ret, 'val', 'set_cached returns value';
    ok $ctrl->cache->{custom}{expires} > time() + 200, 'custom TTL applied';
};

# ============================================
# render_error
# ============================================
subtest 'render_error with default status' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    $ctrl->render_error($c, 'Something failed');
    my $r = $c->rendered;
    is $r->{status}, 500, 'default status 500';
    is $r->{json}{error}, 'Something failed', 'error message in response';
};

subtest 'render_error with custom status' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    $ctrl->render_error($c, 'Not found', 404);
    is $c->rendered->{status}, 404, 'custom status 404';
};

subtest 'render_error with 400' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    $ctrl->render_error($c, 'Bad request', 400);
    is $c->rendered->{status}, 400, 'status 400';
};

# ============================================
# safe_execute
# ============================================
subtest 'safe_execute runs callback normally' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    my $ran = 0;

    $ctrl->safe_execute($c, sub { $ran = 1 });
    ok $ran, 'callback executed';
    is $c->rendered, undef, 'no error rendered';
};

subtest 'safe_execute catches exceptions' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;

    $ctrl->safe_execute($c, sub { die "Something broke\n" });
    is $c->rendered->{status}, 500, 'exception results in 500';
    like $c->rendered->{json}{error}, qr/Something broke/, 'error message includes exception';
};

# ============================================
# require_feature
# ============================================
subtest 'require_feature with no license_info passes' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    ok $ctrl->require_feature($c, 'pattern_analysis'), 'no license_info = pass';
};

subtest 'require_feature with allowed feature passes' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'pro',
            features => ['log_search', 'pattern_analysis'],
        },
    });
    ok $ctrl->require_feature($c, 'pattern_analysis'), 'feature in list passes';
};

subtest 'require_feature with missing feature returns 403' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'free',
            features => ['log_search'],
        },
    });
    ok !$ctrl->require_feature($c, 'audit_log'), 'missing feature rejected';
    is $c->rendered->{status}, 403, '403 forbidden';
    like $c->rendered->{json}{error}, qr/Pro or Enterprise/, 'upgrade message';
    is $c->rendered->{json}{feature}, 'audit_log', 'requested feature in response';
};

subtest 'require_feature with enterprise plan bypasses feature check' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'enterprise',
            features => [],
        },
    });
    ok $ctrl->require_feature($c, 'dashboards'), 'enterprise plan passes dashboards';
    ok $ctrl->require_feature($c, 'backup'), 'enterprise plan passes backup';
    ok $ctrl->require_feature($c, 'any_feature'), 'enterprise plan passes any feature';
    is $c->rendered, undef, 'no error rendered';
};

# ============================================
# Feature-name alias layer (FIX: license grants 'custom_dashboards',
# internal gate is 'dashboards' — the alias must satisfy the gate)
# ============================================
subtest 'has_feature: alias satisfies the canonical gate name' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'pro',                    # NOT enterprise
            features => ['custom_dashboards'],    # alias, not 'dashboards'
        },
    });
    ok $ctrl->has_feature($c, 'dashboards'),
        "pro license granting 'custom_dashboards' satisfies 'dashboards' gate";
    ok $ctrl->require_feature($c, 'dashboards'),
        'require_feature passes via alias (no 403)';
    is $c->rendered, undef, 'no error rendered when alias present';
};

subtest 'has_feature: canonical name still works directly' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'pro',
            features => ['dashboards'],           # canonical name directly
        },
    });
    ok $ctrl->has_feature($c, 'dashboards'), 'canonical name matches itself';
};

subtest 'has_feature: gate rejected when neither name nor alias present' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'pro',
            features => ['log_search'],           # neither dashboards nor alias
        },
    });
    ok !$ctrl->has_feature($c, 'dashboards'),
        'no dashboards and no alias = denied';
    ok !$ctrl->require_feature($c, 'dashboards'), 'require_feature denies';
    is $c->rendered->{status}, 403, '403 returned';
};

subtest 'has_feature: alias does not leak to unrelated gates' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan     => 'pro',
            features => ['custom_dashboards'],
        },
    });
    # The dashboards alias must not accidentally satisfy some other gate.
    ok !$ctrl->has_feature($c, 'backup'),
        "'custom_dashboards' does not satisfy an unrelated 'backup' gate";
};

subtest 'has_feature: enterprise bypass unaffected by alias layer' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => { plan => 'enterprise', features => [] },
    });
    ok $ctrl->has_feature($c, 'dashboards'), 'enterprise still bypasses';
};

subtest 'has_feature: unlicensed (no license_info) still allowed' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;   # no license_info in stash
    ok $ctrl->has_feature($c, 'dashboards'), 'unlicensed allows the gate';
};

# ============================================
# check_limit
# ============================================
subtest 'check_limit with no license_info passes' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new;
    ok $ctrl->check_limit($c, 'alerts', 10), 'no license = pass';
};

subtest 'check_limit within limits passes' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan   => 'free',
            limits => { alerts => 3 },
        },
    });
    ok $ctrl->check_limit($c, 'alerts', 2), '2 < 3 = pass';
};

subtest 'check_limit at limit returns 403' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan   => 'free',
            limits => { alerts => 3 },
        },
    });
    ok !$ctrl->check_limit($c, 'alerts', 3), '3 >= 3 = denied';
    is $c->rendered->{status}, 403, 'limit exceeded returns 403';
    like $c->rendered->{json}{error}, qr/Limit reached/, 'limit error message';
};

subtest 'check_limit with no defined limit passes' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => MockStorage->new);
    my $c = MockMojoCtrl->new({
        license_info => {
            plan   => 'enterprise',
            limits => {},
        },
    });
    ok $ctrl->check_limit($c, 'alerts', 999), 'no limit defined = pass';
};

subtest 'imported functions do not become controller methods' => sub {
    # `use Purl::Util::SearchQuery` sat AFTER `use namespace::clean`, so
    # plan_search_query was never cleaned and every controller subclass
    # inherited it as a method — a second, unintended way to call it that no
    # caller would find in Base.pm's API.
    ok !Purl::API::Controller::Base->can('plan_search_query'),
        'plan_search_query is not part of the controller API';
    ok +(Purl::API::Controller::Base->can('_apply_query')),
        'the wrapper that IS the API is';
};

done_testing;

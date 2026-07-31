#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use JSON::XS ();

use Purl::API::Middleware::License;
use Purl::License::Plans;

# Helper: create a temp config dir with an expired trial (forces free plan)
sub _expired_trial_dir {
    my $dir = tempdir(CLEANUP => 1);
    my $trial_file = "$dir/trial.json";
    open my $fh, '>', $trial_file or die "Cannot write $trial_file: $!";
    print $fh JSON::XS::encode_json({ started_at => 1000000, expires_at => 1000001 });
    close $fh;
    return $dir;
}

# ============================================
# Free plan defaults (no license key, expired trial)
# ============================================
subtest 'free plan when no license key' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;
    is $info->{plan}, 'free', 'defaults to free plan';
    ok $info->{valid}, 'free plan is valid';
    is_deeply $info->{features}, Purl::License::Plans::features_for('free'),
        'free features come from the canonical catalogue';
};

# --- REGRESSION: free tier must match purl-web src/lib/stripe/config.ts ------
# The old free plan granted 3 features and metered servers/users/alerts to
# tiny finite numbers. purl-web now sells free as "unlimited, self-hosted",
# so anything finite here is a promise the backend breaks.
subtest 'free plan grants every self-hosted feature' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;

    for my $feature (qw(log_search live_tail basic_alerts pattern_analysis
                        saved_searches_unlimited telegram_alerts slack_alerts
                        self_hosted)) {
        ok $lic->is_feature_allowed($feature), "free grants $feature";
    }
    ok !$lic->is_feature_allowed('dashboards'), 'free does NOT grant dashboards';
    ok !$lic->is_feature_allowed('ai_query'),   'free does NOT grant ai_query';
    ok !$lic->is_feature_allowed('sso'),        'free does NOT grant sso';
};

subtest 'free plan limits are all unlimited (-1)' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;

    for my $limit (qw(servers agents users alerts saved_searches)) {
        is $info->{limits}{$limit}, -1, "free $limit limit is unlimited";
    }
    ok !exists $info->{limits}{retention_days},
        'retention_days is not a plan limit (PURL_RETENTION_DAYS owns it)';
};

subtest 'removed dead limit accessors stay removed' => sub {
    my $lic = Purl::API::Middleware::License->new;
    ok !$lic->can('get_retention_limit'),
        'get_retention_limit removed — nothing read it';
    ok !$lic->can('check_server_limit'),
        'check_server_limit removed — duplicated Controller::Base::check_limit';
};

subtest 'free plan when PURL_LICENSE_KEY not set' => sub {
    delete $ENV{PURL_LICENSE_KEY};
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;
    is $info->{plan}, 'free', 'no env var = free plan';
};

# ============================================
# Trial plan (14-day Pro trial, no license key)
# ============================================
subtest 'trial plan auto-starts when no trial file exists' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = tempdir(CLEANUP => 1);
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;
    is $info->{plan}, 'trial', 'auto-starts trial plan';
    ok $info->{valid}, 'trial is valid';
    ok $info->{trial}, 'trial flag set';
    ok $info->{trial_days_remaining} > 0, 'trial days remaining > 0';
    ok $info->{trial_days_remaining} <= 14, 'trial days remaining <= 14';
    ok $info->{trial_expires_at}, 'trial_expires_at set';
    ok $info->{trial_started_at}, 'trial_started_at set';
    ok grep({ $_ eq 'pattern_analysis' } @{$info->{features}}), 'trial has pattern_analysis';
    ok grep({ $_ eq 'saved_searches_unlimited' } @{$info->{features}}), 'trial has saved_searches_unlimited';
    is $info->{limits}{servers}, -1, 'trial server limit unlimited';
    is $info->{limits}{users}, -1, 'trial user limit unlimited';
};

# --- REGRESSION: trial must be EXACTLY Pro ----------------------------------
# The old hand-written trial list granted ai_query and audit_logs (Pro/Ent
# features) but omitted dashboards (a Pro feature). Both directions are churn
# machines: trial -> pay used to REMOVE ai_query/audit_logs, and dashboards
# were never demoed to the people most likely to buy them.
subtest 'trial features are exactly the Pro feature list' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = tempdir(CLEANUP => 1);
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;

    is_deeply [sort @{$info->{features}}],
              [sort @{Purl::License::Plans::features_for('pro')}],
              'trial feature set == pro feature set';

    ok $lic->is_feature_allowed('dashboards'),
        'trial grants dashboards (Pro feature the old trial list omitted)';
    ok !$lic->is_feature_allowed('audit_logs'),
        'trial does NOT grant audit_logs — Enterprise-only, would vanish on upgrade to Pro';
    ok !$lic->is_feature_allowed('sso'),
        'trial does NOT grant sso — Enterprise-only';
};

subtest 'no trial feature disappears when upgrading to Pro' => sub {
    my %pro = map { $_ => 1 } @{Purl::License::Plans::features_for('pro')};
    my @lost = grep { !$pro{$_} } @{Purl::License::Plans::features_for('trial')};
    is_deeply \@lost, [], 'paying for Pro never takes a trial feature away';
};

subtest 'trial plan expires to free plan' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;
    is $info->{plan}, 'free', 'expired trial = free plan';
    ok !$info->{trial}, 'no trial flag on free plan';
};

subtest 'trial skipped when license key exists' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'some-jwt-key';
    local $ENV{PURL_CONFIG_DIR} = tempdir(CLEANUP => 1);
    delete $ENV{PURL_LICENSE_PUBLIC_KEY};
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->get_license_info;
    isnt $info->{plan}, 'trial', 'trial not used when license key present';
};

subtest 'trial file persisted across instances' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    my $dir = tempdir(CLEANUP => 1);
    local $ENV{PURL_CONFIG_DIR} = $dir;

    # First instance creates trial
    my $lic1 = Purl::API::Middleware::License->new;
    my $info1 = $lic1->get_license_info;
    is $info1->{plan}, 'trial', 'first instance starts trial';

    # Second instance reads same trial
    my $lic2 = Purl::API::Middleware::License->new;
    my $info2 = $lic2->get_license_info;
    is $info2->{plan}, 'trial', 'second instance reads existing trial';
    is $info2->{trial_expires_at}, $info1->{trial_expires_at}, 'same expiry timestamp';
};

# ============================================
# get_license_key / get_api_url / get_cache_ttl
# ============================================
subtest 'get_license_key from ENV' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'test-jwt-key';
    my $lic = Purl::API::Middleware::License->new;
    is $lic->get_license_key, 'test-jwt-key', 'reads from ENV';
};

subtest 'get_api_url default (no settings)' => sub {
    delete $ENV{PURL_LICENSE_API_URL};
    # Without settings object, returns empty string (defined value short-circuits //)
    my $lic = Purl::API::Middleware::License->new;
    is $lic->get_api_url, '', 'no settings = empty string';
};

subtest 'get_api_url from ENV' => sub {
    local $ENV{PURL_LICENSE_API_URL} = 'https://custom.api.com';
    my $lic = Purl::API::Middleware::License->new;
    is $lic->get_api_url, 'https://custom.api.com', 'custom API URL from ENV';
};

subtest 'get_cache_ttl default (no settings)' => sub {
    delete $ENV{PURL_LICENSE_CACHE_TTL};
    # Without settings object, falls through to default 3600
    my $lic = Purl::API::Middleware::License->new;
    is $lic->get_cache_ttl, 3600, 'no settings = default 3600';
};

# ============================================
# License info caching
# ============================================
subtest 'license info is cached' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    my $info1 = $lic->get_license_info;
    my $info2 = $lic->get_license_info;
    is $info1, $info2, 'same reference returned (cached)';
};

# ============================================
# Feature checks
# ============================================
subtest 'is_feature_allowed for free plan' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    ok $lic->is_feature_allowed('log_search'), 'log_search allowed on free';
    ok $lic->is_feature_allowed('live_tail'), 'live_tail allowed on free';
    ok $lic->is_feature_allowed('basic_alerts'), 'basic_alerts allowed on free';
    ok $lic->is_feature_allowed('pattern_analysis'), 'pattern_analysis now on free';
    ok !$lic->is_feature_allowed('audit_log'), 'audit_log not on free';
};

# ============================================
# Plan catalogue (single source of truth)
# ============================================
subtest 'plan catalogue is cumulative' => sub {
    my %free = map { $_ => 1 } @{Purl::License::Plans::features_for('free')};
    my %pro  = map { $_ => 1 } @{Purl::License::Plans::features_for('pro')};
    my %ent  = map { $_ => 1 } @{Purl::License::Plans::features_for('enterprise')};

    is_deeply [grep { !$pro{$_} } keys %free], [], 'pro is a superset of free';
    is_deeply [grep { !$ent{$_} } keys %pro],  [], 'enterprise is a superset of pro';
    ok $ent{sso} && $ent{ldap_auth} && $ent{audit_logs}, 'enterprise adds identity/compliance';
};

subtest 'plan catalogue returns fresh copies' => sub {
    my $a = Purl::License::Plans::features_for('free');
    push @$a, 'injected_feature';
    my $b = Purl::License::Plans::features_for('free');
    ok !(grep { $_ eq 'injected_feature' } @$b), 'catalogue cannot be mutated by a caller';

    my $l = Purl::License::Plans::unlimited_limits();
    $l->{users} = 1;
    is Purl::License::Plans::unlimited_limits()->{users}, -1, 'limits hashref is a fresh copy';
};

subtest 'unknown plan falls back to free' => sub {
    is_deeply Purl::License::Plans::features_for('platinum'),
              Purl::License::Plans::features_for('free'),
              'unknown plan name degrades to free, never to pro';
    is_deeply Purl::License::Plans::features_for(undef),
              Purl::License::Plans::features_for('free'),
              'undef plan degrades to free';
};

# ============================================
# Plan and limit checks
# ============================================
subtest 'get_plan returns free' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;
    is $lic->get_plan, 'free', 'free plan returned';
};

# ============================================
# check_license middleware
# ============================================
subtest 'check_license attaches info to stash' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    local $ENV{PURL_CONFIG_DIR} = _expired_trial_dir();
    my $lic = Purl::API::Middleware::License->new;

    my %stash;
    my $c = bless {}, 'MockLicCtrl';
    no warnings 'once';
    *MockLicCtrl::stash = sub {
        my ($self, $key, $val) = @_;
        $stash{$key} = $val if defined $val;
        return $stash{$key};
    };

    my $result = $lic->check_license($c);
    is $result, 1, 'check_license always returns 1';
    is $stash{license_plan}, 'free', 'plan attached to stash';
    ok ref $stash{license_info} eq 'HASH', 'license_info attached as hash';
};

# ============================================
# JWT offline verification (mocked)
# ============================================
subtest 'JWT verification with no public key falls through' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'some.jwt.token';
    delete $ENV{PURL_LICENSE_PUBLIC_KEY};
    my $lic = Purl::API::Middleware::License->new;
    my $result = $lic->_verify_jwt_offline('some.jwt.token');
    is $result, undef, 'no public key returns undef (signals API fallback)';
};

subtest 'JWT verification with invalid key returns error' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'invalid.jwt.token';
    local $ENV{PURL_LICENSE_PUBLIC_KEY} = 'not-a-real-key';
    my $lic = Purl::API::Middleware::License->new;
    my $result = $lic->_verify_jwt_offline('invalid.jwt.token');
    ok $result, 'result returned';
    ok !$result->{valid}, 'not valid';
    like $result->{error} // '', qr/JWT verification failed|Crypt::JWT/, 'error message present';
};

# ============================================
# activate_with_api (mocked HTTP)
# ============================================
subtest 'activate_with_api no license key returns free' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->activate_with_api;
    is $info->{plan}, 'free', 'no key = free plan';
};

subtest 'activate_with_api failed HTTP returns free' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'test-key';
    delete $ENV{PURL_LICENSE_PUBLIC_KEY};
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub {
        return { success => 0, status => 500, content => '{"error":"server down"}' };
    });

    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->activate_with_api;
    is $info->{plan}, 'free', 'failed activation falls to free';
    ok !$info->{valid} || $info->{plan} eq 'free', 'not a paid plan';
};

subtest 'activate_with_api successful activation' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'test-key';
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub {
        return {
            success => 1,
            status  => 200,
            content => '{"activated":true,"plan":"pro","features":["log_search","live_tail","basic_alerts","pattern_analysis"],"limits":{"servers":10,"retention_days":30},"expiresAt":"2027-01-01T00:00:00Z"}',
        };
    });

    my $lic = Purl::API::Middleware::License->new;
    my $info = $lic->activate_with_api;
    is $info->{plan}, 'pro', 'pro plan activated';
    ok $info->{valid}, 'license valid';
    ok $info->{activated}, 'marked as activated';
    ok grep({ $_ eq 'pattern_analysis' } @{$info->{features}}), 'pro features present';
};

# ============================================
# send_heartbeat / deactivate (non-blocking)
# ============================================
subtest 'send_heartbeat with no license does nothing' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    my $lic = Purl::API::Middleware::License->new;
    # Should not die
    eval { $lic->send_heartbeat };
    ok !$@, 'heartbeat with no key does not die';
};

subtest 'deactivate with no license does nothing' => sub {
    local $ENV{PURL_LICENSE_KEY} = '';
    my $lic = Purl::API::Middleware::License->new;
    eval { $lic->deactivate };
    ok !$@, 'deactivate with no key does not die';
};

subtest 'send_heartbeat calls API' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'test-key';
    my $called = 0;
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub { $called++; return { success => 1 } });

    my $lic = Purl::API::Middleware::License->new;
    $lic->send_heartbeat;
    ok $called, 'HTTP POST called for heartbeat';
};

subtest 'deactivate calls API' => sub {
    local $ENV{PURL_LICENSE_KEY} = 'test-key';
    my $called = 0;
    my $http_mock = Test::MockModule->new('HTTP::Tiny');
    $http_mock->redefine('post', sub { $called++; return { success => 1 } });

    my $lic = Purl::API::Middleware::License->new;
    $lic->deactivate;
    ok $called, 'HTTP POST called for deactivation';
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Spec ();
use POSIX ();

# ============================================================
# REGRESSION: alerts must fire SERVER-side.
#
# check_alerts() used to be reachable only from POST /api/alerts/check, and
# the only caller of that endpoint was the browser dashboard. Close the tab
# and no Telegram/Slack/webhook notification was ever sent again — the core
# product promise silently did nothing.
#
# The fix registers a Mojo::IOLoop->recurring timer in Server.pm, gated on
# cron leadership so exactly ONE prefork worker evaluates the rules.
#
# What this file pins:
#   1. Purl::Alert::Scheduler exists and evaluates + notifies with no HTTP
#      context (the property that makes server-side scheduling possible).
#   2. Interval resolution: ENV > settings > default, 0 == disabled, and a
#      floor so a mistyped interval cannot hammer ClickHouse.
#   3. Cron::run_alert_check() runs the check ONLY in the cron leader — a
#      non-leader process must NOT send duplicate notifications.
#   4. setup_routes() actually registers a recurring timer for it.
#   5. The controller endpoint and the timer share ONE implementation.
# ============================================================

require Purl::API::Server;
require Purl::Alert::Scheduler;
require Purl::API::Controller::Alerts;

# ------------------------------------------------------------
# Mocks
# ------------------------------------------------------------
{
    package MockAlertStorage;
    sub new { bless { triggered => $_[1] // [], calls => 0 }, $_[0] }
    sub check_alerts { $_[0]{calls}++; return $_[0]{triggered} }
    sub calls { $_[0]{calls} }

    package DyingStorage;
    sub new { bless {}, $_[0] }
    sub check_alerts { die "clickhouse unreachable\n" }

    package MockNotifier;
    sub new { bless { sent => [] }, $_[0] }
    sub notify { my ($s, $a, $ctx) = @_; push @{$s->{sent}}, $a->{name}; return 1 }
    sub sent { $_[0]{sent} }
}

# ============================================================
# 1. Scheduler evaluates and notifies with NO HTTP context
# ============================================================
subtest 'scheduler runs alerts and notifies without any request context' => sub {
    my $telegram = MockNotifier->new;
    my $storage  = MockAlertStorage->new([
        { name => 'high-errors', notify_type => 'telegram', count => 42 },
    ]);

    my $sched = Purl::Alert::Scheduler->new(
        storage   => $storage,
        notifiers => { telegram => $telegram },
    );

    my $result = $sched->run_once();

    is $storage->calls, 1, 'check_alerts was evaluated once';
    is scalar @{ $result->{triggered} }, 1, 'one alert triggered';
    is_deeply $telegram->sent, ['high-errors'], 'telegram notifier was invoked';
    is_deeply $result->{notifications},
        [ { alert => 'high-errors', sent => ['telegram'] } ],
        'notification result reports the channel that accepted it';
};

subtest 'scheduler is a no-op when nothing triggers' => sub {
    my $telegram = MockNotifier->new;
    my $sched = Purl::Alert::Scheduler->new(
        storage   => MockAlertStorage->new([]),
        notifiers => { telegram => $telegram },
    );
    my $result = $sched->run_once();
    is_deeply $result->{triggered}, [], 'nothing triggered';
    is_deeply $result->{notifications}, [], 'nothing notified';
    is_deeply $telegram->sent, [], 'notifier untouched';
};

# ============================================================
# 2. Interval resolution
# ============================================================
subtest 'alert check interval: ENV > settings > default' => sub {
    my $settings = MockSettings->new(45);

    {
        local $ENV{PURL_ALERT_CHECK_INTERVAL} = '120';
        is Purl::API::Server::Cron::alert_check_interval($settings), 120,
            'PURL_ALERT_CHECK_INTERVAL wins over settings';
    }

    {
        local %ENV = %ENV;
        delete $ENV{PURL_ALERT_CHECK_INTERVAL};
        is Purl::API::Server::Cron::alert_check_interval($settings), 45,
            'settings alerts.check_interval_seconds is used when no ENV';
        is Purl::API::Server::Cron::alert_check_interval(undef), 60,
            'default is 60s with neither ENV nor settings';
    }

    # Regression: templating an unset Helm value yields PURL_ALERT_CHECK_INTERVAL="".
    # Treating that as "junk" disabled alerting entirely on a default install.
    {
        local $ENV{PURL_ALERT_CHECK_INTERVAL} = '';
        is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 60,
            'empty env var falls back to the default, it does NOT disable alerting';
        is Purl::API::Server::Cron::alert_check_interval($settings), 45,
            'empty env var falls through to settings';
    }

    {
        local $ENV{PURL_ALERT_CHECK_INTERVAL} = ' 90 ';
        is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 90,
            'surrounding whitespace is trimmed, not treated as junk';
    }
};

subtest 'alert check interval: 0 disables, junk disables, low values floored' => sub {
    local %ENV = %ENV;

    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';
    is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 0, '0 disables the timer';

    $ENV{PURL_ALERT_CHECK_INTERVAL} = 'not-a-number';
    is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 0, 'junk disables the timer';

    $ENV{PURL_ALERT_CHECK_INTERVAL} = '-5';
    is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 0, 'negative disables the timer';

    $ENV{PURL_ALERT_CHECK_INTERVAL} = '1';
    is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 10,
        '1s is raised to the 10s floor (check_alerts scans every rule)';

    $ENV{PURL_ALERT_CHECK_INTERVAL} = '300';
    is Purl::API::Server::Cron::alert_check_interval(MockSettings->new(undef)), 300, 'sane values pass through';
};

# ============================================================
# 3. Leader gate — the property that stops N workers sending N messages
# ============================================================
my $lock = File::Spec->catfile(File::Spec->tmpdir, "purl-alert-lead-$$.lock");
unlink $lock;

subtest 'leader runs the check; a non-leader process does NOT' => sub {
    $Purl::API::Server::Cron::CRON_LEADER_FH = undef;

    my $storage = MockAlertStorage->new([
        { name => 'disk-full', notify_type => 'telegram', count => 7 },
    ]);
    my $telegram = MockNotifier->new;
    my $sched = Purl::Alert::Scheduler->new(
        storage   => $storage,
        notifiers => { telegram => $telegram },
    );

    # This process takes leadership and runs.
    my $result = Purl::API::Server::Cron::run_alert_check($sched, $lock);
    ok defined $result, 'leader ran the check';
    is $storage->calls, 1, 'check_alerts evaluated exactly once';
    is_deeply $telegram->sent, ['disk-full'], 'leader sent the notification';

    # A second, independent process must be denied while we hold the lock.
    my $pid = fork();
    if (!defined $pid) {
        diag("fork failed: $! -- skipping non-leader check");
    }
    elsif ($pid == 0) {
        $Purl::API::Server::Cron::CRON_LEADER_FH = undef;   # drop inherited leadership
        my $child_storage = MockAlertStorage->new([
            { name => 'disk-full', notify_type => 'telegram', count => 7 },
        ]);
        my $child_sched = Purl::Alert::Scheduler->new(
            storage   => $child_storage,
            notifiers => { telegram => MockNotifier->new },
        );
        my $r = Purl::API::Server::Cron::run_alert_check($child_sched, $lock);
        # exit 0 == correctly skipped (no result, no evaluation)
        POSIX::_exit((!defined $r && $child_storage->calls == 0) ? 0 : 1);
    }
    else {
        waitpid($pid, 0);
        is $? >> 8, 0,
            'non-leader worker did NOT evaluate alerts (no duplicate notifications)';
    }
};

subtest 'a failing storage does not propagate out of the timer tick' => sub {
    $Purl::API::Server::Cron::CRON_LEADER_FH = undef;
    my $sched = Purl::Alert::Scheduler->new(storage => DyingStorage->new);
    my $result = Purl::API::Server::Cron::run_alert_check($sched, $lock);
    ok defined $result, 'tick returned instead of dying';
    like $result->{error}, qr/clickhouse unreachable/, 'error is reported, not thrown';
    is_deeply $result->{triggered}, [], 'no alerts claimed as triggered';
};

close $Purl::API::Server::Cron::CRON_LEADER_FH if $Purl::API::Server::Cron::CRON_LEADER_FH;
$Purl::API::Server::Cron::CRON_LEADER_FH = undef;
unlink $lock;

# ============================================================
# 4. setup_routes registers the recurring timer
# ============================================================
subtest 'setup_routes registers a recurring alert timer' => sub {
    my @recurring;
    {
        no warnings 'redefine';
        my $orig = \&Mojo::IOLoop::recurring;
        local *Mojo::IOLoop::recurring = sub {
            my ($self, $after, $cb) = @_;
            push @recurring, $after;
            return 'stub-timer-id';
        };

        local $ENV{PURL_ALERT_CHECK_INTERVAL} = '90';
        local $ENV{PURL_CONFIG_FILE}  = "/tmp/purl_alert_sched_$$/settings.json";
        local $ENV{PURL_CONFIG_DIR}   = "/tmp/purl_alert_sched_$$";
        local $ENV{PURL_AUTH_ENABLED} = '0';
        local $ENV{PURL_BROADCAST_MODE} = 'local';

        require File::Path;
        File::Path::make_path($ENV{PURL_CONFIG_DIR});

        {
            no warnings 'redefine';
            *Purl::API::Server::_build_storage = sub { MockAlertStorage->new([]) };
        }

        my $server = Purl::API::Server->create(config => {});
        $server->setup_routes;
    }

    ok scalar(grep { $_ == 90 } @recurring),
        'a recurring timer was registered at the configured 90s alert interval'
        or diag("registered intervals: @recurring");
};

# ============================================================
# 5. The HTTP endpoint and the timer share ONE implementation
# ============================================================
subtest 'Controller::Alerts::check delegates to the same Scheduler' => sub {
    my $telegram = MockNotifier->new;
    my $storage  = MockAlertStorage->new([
        { name => 'shared-path', notify_type => 'telegram', count => 3 },
    ]);

    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => $storage,
        notifiers => { telegram => $telegram },
    );

    isa_ok $ctrl->scheduler, 'Purl::Alert::Scheduler',
        'controller exposes a Scheduler';

    my $c = MockCtrl->new;
    $ctrl->check($c);

    is $storage->calls, 1, 'endpoint evaluated the rules';
    is_deeply $telegram->sent, ['shared-path'],
        'endpoint sent through the same notifier path the timer uses';
    is_deeply $c->rendered->{json}{notifications},
        [ { alert => 'shared-path', sent => ['telegram'] } ],
        'endpoint response shape is unchanged';
};

done_testing;

# ------------------------------------------------------------
# Support packages
# ------------------------------------------------------------
{
    # Mirrors Purl::Config::get precedence for this key: ENV wins, but an
    # empty-or-missing env var falls through. Cron::alert_check_interval delegates
    # to this rather than reading %ENV itself, so the mock must model it — an
    # unfaithful mock is what let PURL_ALERT_CHECK_INTERVAL="" ship as
    # "alerting silently disabled".
    package MockSettings;
    sub new { bless { interval => $_[1] }, $_[0] }
    sub get {
        my ($self, $section, $key) = @_;
        return undef unless $section eq 'alerts' && $key eq 'check_interval_seconds';

        my $env = $ENV{PURL_ALERT_CHECK_INTERVAL};
        return $env if defined $env && $env ne '';

        return $self->{interval};
    }

    package MockCtrl;
    sub new { bless { rendered => undef }, $_[0] }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]{rendered} }
    sub stash { return undef }
    sub session { return undef }
    sub app { return $_[0] }
    sub log { return $_[0] }
    sub error { }
    sub warn { }
}

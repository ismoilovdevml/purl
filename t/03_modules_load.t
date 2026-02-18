#!/usr/bin/env perl
# Smoke test: verify all core modules compile without errors
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

my @modules = qw(
    Purl::Config
    Purl::Util::Time
    Purl::API::Middleware
    Purl::API::Middleware::Auth
    Purl::API::Middleware::License
    Purl::API::Controller::Base
    Purl::API::Controller::Logs
    Purl::API::Controller::Auth
    Purl::API::Controller::Alerts
    Purl::API::Controller::Settings
    Purl::API::Controller::Patterns
    Purl::API::Controller::Traces
    Purl::API::Controller::System
    Purl::API::Controller::Analytics
    Purl::API::Controller::Stats
    Purl::API::Controller::SavedSearches
    Purl::API::Controller::Config
    Purl::API::Controller::Audit
    Purl::API::Controller::Backup
    Purl::API::Controller::AlertTemplates
    Purl::API::Controller::K8sHealth
    Purl::Broadcast::Local
    Purl::Broadcast::Redis
    Purl::Alert::Telegram
    Purl::Alert::Slack
    Purl::Alert::Webhook
    Purl::Storage::ClickHouse
);

for my $module (@modules) {
    use_ok($module);
}

done_testing();

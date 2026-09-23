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
    Purl::API::Middleware::Auth
    Purl::API::Middleware::Auth::Password
    Purl::API::Middleware::Auth::CSRF
    Purl::API::Middleware::Auth::RateLimit
    Purl::API::Middleware::Auth::LoginLockout
    Purl::API::Controller::Base
    Purl::API::Controller::Logs
    Purl::API::Controller::Auth
    Purl::API::Controller::SSOStatus
    Purl::API::Controller::Alerts
    Purl::API::Controller::Settings
    Purl::API::Controller::Settings::Notifications
    Purl::API::Controller::Settings::ApiKeys
    Purl::API::Controller::Settings::Users
    Purl::API::Controller::Settings::LDAP
    Purl::API::Controller::Settings::SSO
    Purl::API::Controller::Settings::AI
    Purl::API::Controller::Settings::Redis
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
    Purl::Storage::ClickHouse::Connection
    Purl::Storage::ClickHouse::CircuitBreaker
    Purl::Storage::ClickHouse::Schema
    Purl::Storage::ClickHouse::Ingest
    Purl::Storage::ClickHouse::Search
    Purl::Storage::ClickHouse::Traces
    Purl::API::Server::Builders
    Purl::API::Server::Bootstrap
    Purl::API::Server::Cron
    Purl::API::Server::Hooks
    Purl::API::Routes
    Purl::API::Routes::System
    Purl::API::Routes::Logs
    Purl::API::Routes::Management
    Purl::API::Routes::Integrations
    Purl::API::Routes::LiveTail
);

for my $module (@modules) {
    use_ok($module);
}

# There is exactly ONE auth gate.
#
# Purl::API::Middleware was a second, unrouted copy of it — its own
# `$ENV{PURL_AUTH_ENABLED} // $auth_config->{enabled}` resolution (the pattern
# Purl::Config::auth_enabled replaced) and a plain-text password comparison.
# Nothing routed to it, so it could not be wrong in production, but it could be
# read as the rule and copied back in. It is deleted; this keeps it deleted.
subtest 'no second auth middleware exists' => sub {
    my ($dead) = grep { -e "$_/Purl/API/Middleware.pm" } "$Bin/../lib";
    ok !$dead, 'lib/Purl/API/Middleware.pm is gone';
    ok -e "$Bin/../lib/Purl/API/Middleware/Auth.pm", 'the real one is still there';
};

# Purl is fully open source: there is no licensing layer to load, and none
# may creep back in under the old module names.
subtest 'no licensing modules exist' => sub {
    ok !-e "$Bin/../lib/Purl/API/Middleware/License.pm", 'License middleware is gone';
    ok !-e "$Bin/../lib/Purl/License/Plans.pm",          'License::Plans is gone';
};

done_testing();

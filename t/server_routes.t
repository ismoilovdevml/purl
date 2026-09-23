#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);
use B ();
use B::Deparse ();
use Scalar::Util qw(blessed);

# ============================================
# Route table pin (#25). Route registration was split out of Server.pm into
# Purl::API::Routes and one module per area (Purl::API::Routes::*). Mojolicious
# matches in DEFINITION ORDER, so the split must keep every route, its HTTP
# method, its nesting under the auth gates and its position. This lists the
# full table the app registers and compares it to the pinned one below.
# ============================================

my $DIR;
BEGIN {
    $DIR = "/tmp/purl_server_routes_test_$$";
    $ENV{PURL_AUTH_ENABLED}         = '1';
    $ENV{PURL_ADMIN_PASSWORD}       = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}         = '0';
    $ENV{PURL_SAML_ENABLED}         = '0';
    $ENV{PURL_SESSION_SECRET}       = 'server-routes-test-secret-0123456789abcdef';
    $ENV{PURL_CONFIG_FILE}          = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}           = $DIR;
    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';
    $ENV{PURL_BROADCAST_MODE}       = 'local';
}
make_path($DIR);
END { remove_tree($DIR) if $DIR }

{
    package Purl::Storage::InMemory;
    use Moo;
    sub flush        { 1 }
    sub maybe_flush  { }
    sub get_metrics  { {} }
    sub log_audit_event    { 1 }
    sub _init_audit_schema { 1 }
}

require Purl::API::Server;
{
    no warnings 'redefine';
    my $storage = Purl::Storage::InMemory->new;
    *Purl::API::Server::_build_storage = sub { return $storage };
}

my $app = Purl::API::Server->create(config => { auth => { enabled => 1 } })->setup_routes;

# Leaf routes in match order, one line each:
#
#   METHOD /full/path [gate,gate] => Controller::Class::method
#
# The gates are the `under` callbacks the request passes on its way (auth,
# the AI rate limit), so moving a route out from under a gate changes its line.
# The handler is read off the route's closure: the controller object it
# captured and the method it calls on it, so wiring a path to the wrong
# controller or method changes its line too.
my %GATE = ('/api' => 'auth', '/api/ai' => 'ai-limit');
my $deparse = B::Deparse->new;

sub handler_of {
    my ($cb) = @_;
    return 'none' unless ref $cb eq 'CODE';

    # Lexicals the closure captured, by name (e.g. '$ldap' => the LDAP controller).
    my %captured;
    my ($names, $vals) = B::svref_2object($cb)->PADLIST->ARRAY;
    my @names = $names->ARRAY;
    my @vals  = $vals->ARRAY;
    for my $i (0 .. $#names) {
        next unless $names[$i] && $names[$i]->can('PV') && defined $names[$i]->PV;
        next unless $vals[$i] && $vals[$i]->can('object_2svref');
        my $ref = $vals[$i]->object_2svref;
        next unless ref $ref eq 'REF';    # a captured scalar holding a reference
        $captured{ $names[$i]->PV } = $$ref if blessed $$ref;
    }

    my $body = $deparse->coderef2text($cb);
    while ($body =~ /(\$\w+)->(\w+)\(/g) {
        my ($var, $method) = ($1, $2);
        my $class = ref($captured{$var} // '') or next;
        return "${class}::$method" if $class =~ /^Purl::API::Controller::/;
    }
    return 'inline';
}

my @got;
my $walk;
$walk = sub {
    my ($r, $prefix, @gates) = @_;
    my $path = $prefix . ($r->pattern->unparsed // '');
    if (@{ $r->children }) {
        push @gates, $GATE{$path} // "gate:$path" if $r->inline && $r->to->{cb};
        $walk->($_, $path, @gates) for @{ $r->children };
        return;
    }
    my $method = $r->is_websocket ? 'WS'
               : $r->methods      ? join('|', @{ $r->methods })
               :                    'ANY';
    my $gates = @gates ? ' [' . join(',', @gates) . ']' : '';
    push @got, "$method $path$gates => " . handler_of($r->to->{cb});
};
$walk->($_, '') for @{ $app->routes->children };

my @want = grep { length } map { s/^\s+|\s+$//gr } split /\n/, <<'ROUTES';
    POST /api/auth/change-password [auth] => Purl::API::Controller::Password::change_password
    GET /api/logs [auth] => Purl::API::Controller::Logs::search
    POST /api/logs [auth] => Purl::API::Controller::Logs::ingest
    GET /api/logs/:id/context [auth] => Purl::API::Controller::Logs::context
    POST /api/query [auth] => Purl::API::Controller::Logs::query
    POST /api/v1/otlp/logs [auth] => Purl::API::Controller::OTLP::ingest
    GET /api/traces/recent [auth] => Purl::API::Controller::Traces::get_recent_traces
    GET /api/traces/:trace_id [auth] => Purl::API::Controller::Traces::get_trace
    GET /api/traces/:trace_id/timeline [auth] => Purl::API::Controller::Traces::get_trace_timeline
    GET /api/requests/:request_id [auth] => Purl::API::Controller::Traces::get_request
    GET /api/stats/fields/#field [auth] => Purl::API::Controller::Stats::field_stats
    GET /api/stats/histogram [auth] => Purl::API::Controller::Stats::histogram
    GET /api/fields [auth] => Purl::API::Controller::Stats::fields
    GET /api/stats [auth] => Purl::API::Controller::Stats::db_stats
    GET /api/analytics/tables [auth] => Purl::API::Controller::Analytics::tables
    GET /api/analytics/queries [auth] => Purl::API::Controller::Analytics::queries
    GET /api/analytics/notifiers [auth] => Purl::API::Controller::Analytics::notifiers
    GET /api/patterns [auth] => Purl::API::Controller::Patterns::list
    GET /api/patterns/:hash/logs [auth] => Purl::API::Controller::Patterns::logs
    GET /api/patterns/stats [auth] => Purl::API::Controller::Patterns::stats
    GET /api/saved-searches [auth] => Purl::API::Controller::SavedSearches::list
    POST /api/saved-searches [auth] => Purl::API::Controller::SavedSearches::create
    DELETE /api/saved-searches/:id [auth] => Purl::API::Controller::SavedSearches::remove
    GET /api/alerts [auth] => Purl::API::Controller::Alerts::list
    POST /api/alerts [auth] => Purl::API::Controller::Alerts::create
    PUT /api/alerts/:id [auth] => Purl::API::Controller::Alerts::update
    DELETE /api/alerts/:id [auth] => Purl::API::Controller::Alerts::remove
    POST /api/alerts/check [auth] => Purl::API::Controller::Alerts::check
    POST /api/alerts/test-notification [auth] => Purl::API::Controller::Alerts::test_notification
    GET /api/alerts/templates [auth] => Purl::API::Controller::AlertTemplates::list
    GET /api/config [auth] => Purl::API::Controller::Config::get_config
    GET /api/config/retention [auth] => Purl::API::Controller::Config::get_retention
    PUT /api/config/retention [auth] => Purl::API::Controller::Config::update_retention
    POST /api/config/test-clickhouse [auth] => Purl::API::Controller::Config::test_clickhouse
    GET /api/sources [auth] => Purl::API::Controller::Config::get_sources
    DELETE /api/cache [auth] => Purl::API::Controller::Config::clear_cache
    GET /api/settings [auth] => Purl::API::Controller::Settings::get_all
    PUT /api/settings/clickhouse [auth] => Purl::API::Controller::Settings::update_clickhouse
    PUT /api/settings/notifications/:type [auth] => Purl::API::Controller::Settings::Notifications::update_notifications
    POST /api/settings/notifications/:type/test [auth] => Purl::API::Controller::Settings::Notifications::test_notification
    PUT /api/settings/retention [auth] => Purl::API::Controller::Settings::update_retention
    GET /api/settings/api-keys [auth] => Purl::API::Controller::Settings::ApiKeys::list_api_keys
    POST /api/settings/api-keys [auth] => Purl::API::Controller::Settings::ApiKeys::generate_api_key
    DELETE /api/settings/api-keys/:key_id [auth] => Purl::API::Controller::Settings::ApiKeys::revoke_api_key
    GET /api/settings/users [auth] => Purl::API::Controller::Settings::Users::list_users
    POST /api/settings/users [auth] => Purl::API::Controller::Settings::Users::create_user
    PUT /api/settings/users/:username [auth] => Purl::API::Controller::Settings::Users::update_user
    DELETE /api/settings/users/:username [auth] => Purl::API::Controller::Settings::Users::delete_user
    GET /api/settings/ldap [auth] => Purl::API::Controller::Settings::LDAP::get_ldap
    PUT /api/settings/ldap [auth] => Purl::API::Controller::Settings::LDAP::update_ldap
    POST /api/settings/ldap/test [auth] => Purl::API::Controller::Settings::LDAP::test_ldap
    GET /api/settings/sso [auth] => Purl::API::Controller::Settings::SSO::get_sso
    PUT /api/settings/sso [auth] => Purl::API::Controller::Settings::SSO::update_sso
    POST /api/settings/sso/test [auth] => Purl::API::Controller::Settings::SSO::test_sso
    GET /api/settings/ai [auth] => Purl::API::Controller::Settings::AI::get_ai
    PUT /api/settings/ai [auth] => Purl::API::Controller::Settings::AI::update_ai
    POST /api/settings/ai/test [auth] => Purl::API::Controller::Settings::AI::test_ai
    GET /api/settings/redis [auth] => Purl::API::Controller::Settings::Redis::get_redis
    PUT /api/settings/redis [auth] => Purl::API::Controller::Settings::Redis::update_redis
    GET /api/agents [auth] => Purl::API::Controller::Agents::list
    POST /api/agents/register [auth] => Purl::API::Controller::Agents::register
    POST /api/agents/heartbeat [auth] => Purl::API::Controller::Agents::heartbeat
    DELETE /api/agents/:id [auth] => Purl::API::Controller::Agents::remove
    GET /api/backup/schedule [auth] => Purl::API::Controller::Backup::get_schedule
    PUT /api/backup/schedule [auth] => Purl::API::Controller::Backup::update_schedule
    GET /api/backup/s3 [auth] => Purl::API::Controller::Backup::get_s3_config
    PUT /api/backup/s3 [auth] => Purl::API::Controller::Backup::update_s3_config
    POST /api/backup/upload-s3 [auth] => Purl::API::Controller::Backup::upload_to_s3
    GET /api/backup [auth] => Purl::API::Controller::Backup::list
    POST /api/backup [auth] => Purl::API::Controller::Backup::create
    POST /api/backup/restore [auth] => Purl::API::Controller::Backup::restore
    GET /api/backup/:id/download [auth] => Purl::API::Controller::Backup::download
    DELETE /api/backup/:id [auth] => Purl::API::Controller::Backup::remove
    GET /api/audit [auth] => Purl::API::Controller::Audit::list
    GET /api/audit/stats [auth] => Purl::API::Controller::Audit::stats
    POST /api/es/_search [auth] => Purl::API::Controller::ESCompat::search
    POST /api/es/_msearch [auth] => Purl::API::Controller::ESCompat::msearch
    GET /api/es/_field_caps [auth] => Purl::API::Controller::ESCompat::field_caps
    POST /api/v1/syslog [auth] => Purl::API::Controller::Syslog::ingest
    GET /api/pipelines [auth] => Purl::API::Controller::Pipeline::list
    GET /api/pipelines/:id [auth] => Purl::API::Controller::Pipeline::get
    POST /api/pipelines [auth] => Purl::API::Controller::Pipeline::create
    PUT /api/pipelines/:id [auth] => Purl::API::Controller::Pipeline::update
    DELETE /api/pipelines/:id [auth] => Purl::API::Controller::Pipeline::remove
    POST /api/pipelines/test [auth] => Purl::API::Controller::Pipeline::test
    GET /api/dashboards [auth] => Purl::API::Controller::Dashboard::list
    GET /api/dashboards/templates [auth] => Purl::API::Controller::Dashboard::list_templates
    GET /api/dashboards/:id [auth] => Purl::API::Controller::Dashboard::get
    POST /api/dashboards [auth] => Purl::API::Controller::Dashboard::create
    POST /api/dashboards/from-template [auth] => Purl::API::Controller::Dashboard::create_from_template
    PUT /api/dashboards/:id [auth] => Purl::API::Controller::Dashboard::update
    DELETE /api/dashboards/:id [auth] => Purl::API::Controller::Dashboard::remove
    POST /api/dashboards/widget [auth] => Purl::API::Controller::Dashboard::execute_widget
    POST /api/v1/k8s-audit [auth] => Purl::API::Controller::K8sAudit::ingest
    GET /api/k8s/health [auth] => Purl::API::Controller::K8sHealth::summary
    GET /api/k8s/health/pods [auth] => Purl::API::Controller::K8sHealth::pods
    POST /api/ai/query [auth,ai-limit] => Purl::API::Controller::AI::query
    POST /api/ai/analyze [auth,ai-limit] => Purl::API::Controller::AI::analyze
    POST /api/ai/explain [auth,ai-limit] => Purl::API::Controller::AI::explain
    GET /api/ai/suggest [auth] => Purl::API::Controller::AI::suggest
    GET /api/ai/providers [auth] => Purl::API::Controller::AI::providers
    GET /api/clusters [auth] => Purl::API::Controller::Clusters::list
    WS /api/logs/stream [auth] => inline
    GET /api/csrf-token => Purl::API::Controller::Auth::csrf_token
    GET /api/health => Purl::API::Controller::System::health
    GET /api/health/live => Purl::API::Controller::System::health_live
    GET /api/health/ready => Purl::API::Controller::System::health_ready
    GET /api/metrics => Purl::API::Controller::System::metrics
    GET /api/metrics/json => Purl::API::Controller::System::metrics_json
    POST /api/auth/login => Purl::API::Controller::Auth::login
    POST /api/auth/logout => Purl::API::Controller::Auth::logout
    GET /api/auth/me => Purl::API::Controller::Auth::me
    GET /api/auth/sso/login => Purl::API::Controller::SSO::sso_login
    POST /api/auth/sso/callback => Purl::API::Controller::SSO::sso_callback
    GET /api/auth/sso/metadata => Purl::API::Controller::SSO::sso_metadata
    GET /api/auth/sso/status => Purl::API::Controller::SSOStatus::status
    ANY /api/*api_path => inline
    GET /*catchall => inline
ROUTES

is scalar(@got), scalar(@want), 'same number of routes as the pinned table';
is_deeply \@got, \@want, 'every route registered with its method, gates and handler, in order'
    or diag join "\n", 'Registered table:', @got;

subtest 'gates and fallbacks sit where matching order needs them' => sub {
    my ($api) = grep { ($_->pattern->unparsed // '') eq '/api' } @{ $app->routes->children };
    ok $api, '/api is registered';

    my @api_children = @{ $api->children };
    ok $api_children[0]->inline, 'the protected auth gate is the first /api child';
    is $api_children[-1]->pattern->unparsed, '/*api_path',
        'the JSON 404 catch-all is the last /api route';
    is $app->routes->children->[-1]->pattern->unparsed, '/*catchall',
        'the SPA fallback is the last route overall';
};

done_testing;

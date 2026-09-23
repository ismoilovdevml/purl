#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);

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

# Leaf routes as "METHOD /full/path", in match order.
my @got;
my $walk;
$walk = sub {
    my ($r, $prefix) = @_;
    my $path = $prefix . ($r->pattern->unparsed // '');
    if (@{ $r->children }) {
        $walk->($_, $path) for @{ $r->children };
        return;
    }
    my $method = $r->is_websocket ? 'WS'
               : $r->methods      ? join('|', @{ $r->methods })
               :                    'ANY';
    push @got, "$method $path";
};
$walk->($_, '') for @{ $app->routes->children };

my @want = grep { length } map { s/^\s+|\s+$//gr } split /\n/, <<'ROUTES';
    POST /api/auth/change-password
    GET /api/logs
    POST /api/logs
    GET /api/logs/:id/context
    POST /api/query
    POST /api/v1/otlp/logs
    GET /api/traces/recent
    GET /api/traces/:trace_id
    GET /api/traces/:trace_id/timeline
    GET /api/requests/:request_id
    GET /api/stats/fields/#field
    GET /api/stats/histogram
    GET /api/fields
    GET /api/stats
    GET /api/analytics/tables
    GET /api/analytics/queries
    GET /api/analytics/notifiers
    GET /api/patterns
    GET /api/patterns/:hash/logs
    GET /api/patterns/stats
    GET /api/saved-searches
    POST /api/saved-searches
    DELETE /api/saved-searches/:id
    GET /api/alerts
    POST /api/alerts
    PUT /api/alerts/:id
    DELETE /api/alerts/:id
    POST /api/alerts/check
    POST /api/alerts/test-notification
    GET /api/alerts/templates
    GET /api/config
    GET /api/config/retention
    PUT /api/config/retention
    POST /api/config/test-clickhouse
    GET /api/sources
    DELETE /api/cache
    GET /api/settings
    PUT /api/settings/clickhouse
    PUT /api/settings/notifications/:type
    POST /api/settings/notifications/:type/test
    PUT /api/settings/retention
    GET /api/settings/api-keys
    POST /api/settings/api-keys
    DELETE /api/settings/api-keys/:key_id
    GET /api/settings/users
    POST /api/settings/users
    PUT /api/settings/users/:username
    DELETE /api/settings/users/:username
    GET /api/settings/ldap
    PUT /api/settings/ldap
    POST /api/settings/ldap/test
    GET /api/settings/sso
    PUT /api/settings/sso
    POST /api/settings/sso/test
    GET /api/settings/ai
    PUT /api/settings/ai
    POST /api/settings/ai/test
    GET /api/settings/redis
    PUT /api/settings/redis
    GET /api/agents
    POST /api/agents/register
    POST /api/agents/heartbeat
    DELETE /api/agents/:id
    GET /api/backup/schedule
    PUT /api/backup/schedule
    GET /api/backup/s3
    PUT /api/backup/s3
    POST /api/backup/upload-s3
    GET /api/backup
    POST /api/backup
    POST /api/backup/restore
    GET /api/backup/:id/download
    DELETE /api/backup/:id
    GET /api/audit
    GET /api/audit/stats
    POST /api/es/_search
    POST /api/es/_msearch
    GET /api/es/_field_caps
    POST /api/v1/syslog
    GET /api/pipelines
    GET /api/pipelines/:id
    POST /api/pipelines
    PUT /api/pipelines/:id
    DELETE /api/pipelines/:id
    POST /api/pipelines/test
    GET /api/dashboards
    GET /api/dashboards/templates
    GET /api/dashboards/:id
    POST /api/dashboards
    POST /api/dashboards/from-template
    PUT /api/dashboards/:id
    DELETE /api/dashboards/:id
    POST /api/dashboards/widget
    POST /api/v1/k8s-audit
    GET /api/k8s/health
    GET /api/k8s/health/pods
    POST /api/ai/query
    POST /api/ai/analyze
    POST /api/ai/explain
    GET /api/ai/suggest
    GET /api/ai/providers
    GET /api/clusters
    WS /api/logs/stream
    GET /api/csrf-token
    GET /api/health
    GET /api/health/live
    GET /api/health/ready
    GET /api/metrics
    GET /api/metrics/json
    POST /api/auth/login
    POST /api/auth/logout
    GET /api/auth/me
    GET /api/auth/sso/login
    POST /api/auth/sso/callback
    GET /api/auth/sso/metadata
    GET /api/auth/sso/status
    ANY /api/*api_path
    GET /*catchall
ROUTES

is scalar(@got), scalar(@want), 'same number of routes as the pinned table';
is_deeply \@got, \@want, 'every route registered, with its method and in order';

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

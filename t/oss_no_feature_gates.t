#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);

# ============================================
# REGRESSION (#77): Purl is fully open source — no licensing layer.
#
# Every request used to pass through a license middleware that stamped the
# plan into the stash, and ~57 require_feature() gates answered 403
# {"error":"This feature requires a Pro or Enterprise license","feature":...}
# on an instance without a license key. This drives the REAL app (routes,
# auth hook, controllers) with no license configured anywhere and pins that:
#   * every formerly gated endpoint answers normally (200, no `feature` key),
#   * the license routes are gone,
#   * GET /api/auth/sso/status is public and reports SSO off,
#   * GET /api/auth/me carries k8s_mode (it used to come from /api/license).
# ============================================

my $DIR;
BEGIN {
    $DIR = "/tmp/purl_oss_gates_test_$$";
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_API_KEYS}        = 'oss-ingest-key';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'oss-gates-test-secret-abcdef0123456789';
    $ENV{PURL_CONFIG_FILE}     = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}      = $DIR;
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
    delete $ENV{KUBERNETES_SERVICE_HOST};
}
make_path($DIR);
END { remove_tree($DIR) if $DIR }

# ============================================
# In-memory storage: just enough for the endpoints under test
# ============================================
{
    package Purl::Storage::InMemory;
    use Moo;
    sub flush        { 1 }
    sub maybe_flush  { }
    sub get_metrics  { { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 } }
    sub log_audit_event { 1 }
    sub _init_audit_schema { 1 }

    sub list_dashboards   { [] }
    sub list_pipelines    { [] }
    sub list_backups      { [] }
    sub get_audit_logs    { [] }
    sub count_audit_logs  { 0 }
    sub get_audit_stats   { {} }
    sub get_patterns      { [] }
    sub get_k8s_pod_count { 0 }
    sub get_pod_health_summary { [] }
    sub get_unhealthy_pods     { [] }
    sub get_alerts        { [] }
    sub create_alert      { 1 }
}

my $storage = Purl::Storage::InMemory->new;

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}

my $server = Purl::API::Server->create(config => { auth => { enabled => 1 } });
my $app    = $server->setup_routes;

use Test::Mojo;
my $t = Test::Mojo->new($app);
$t->post_ok('/api/auth/login',
    { 'Content-Type' => 'application/json' },
    json => { username => 'admin', password => 'StrongAdminPass123' })
  ->status_is(200)
  ->json_is('/authenticated' => 1);

# ============================================
# Formerly license-gated reads: 200, never a feature 403
# ============================================
my @FORMERLY_GATED = (
    '/api/dashboards',        # dashboards
    '/api/pipelines',         # pipelines
    '/api/backup',            # backup
    '/api/audit',             # audit_logs
    '/api/audit/stats',       # audit_logs
    '/api/settings/sso',      # sso
    '/api/settings/ldap',     # ldap_auth
    '/api/k8s/health',        # k8s_monitoring
    '/api/k8s/health/pods',   # k8s_monitoring
);

for my $path (@FORMERLY_GATED) {
    subtest "GET $path answers normally without a license" => sub {
        $t->get_ok($path)->status_is(200);
        my $json = $t->tx->res->json;
        ok !(ref $json eq 'HASH' && exists $json->{feature}), 'no feature-gate body';
    };
}

subtest 'a Telegram alert can be created without a license' => sub {
    $t->get_ok('/api/csrf-token')->status_is(200);
    my $token = $t->tx->res->json->{csrf_token};
    $t->post_ok('/api/alerts',
        { 'Content-Type' => 'application/json', 'X-CSRF-Token' => $token },
        json => { name => 'Errors', query => 'level:ERROR', threshold => 1,
                  notify_type => 'telegram' })
      ->status_is(200)
      ->json_is('/status' => 'ok');
};

# ============================================
# License routes are gone
# ============================================
subtest 'license endpoints no longer exist' => sub {
    # Unknown GETs fall through to the SPA catch-all (index.html), so the
    # proof is that nothing answers with the old plan/features JSON.
    $t->get_ok('/api/license');
    my $json = eval { $t->tx->res->json };
    ok !(ref $json eq 'HASH' && (exists $json->{plan} || exists $json->{features})),
        'GET /api/license no longer returns plan info';

    $t->get_ok('/api/csrf-token');
    my $token = $t->tx->res->json->{csrf_token};
    $t->put_ok('/api/settings/license',
        { 'Content-Type' => 'application/json', 'X-CSRF-Token' => $token },
        json => { key => 'anything' })
      ->status_is(404);
};

subtest 'settings no longer report a license block' => sub {
    $t->get_ok('/api/settings')->status_is(200);
    ok !exists $t->tx->res->json->{license}, 'no license section';
};

# ============================================
# Public probes the login page uses (no session)
# ============================================
subtest 'GET /api/auth/sso/status is public and reports SSO off' => sub {
    my $anon = Test::Mojo->new($app);
    $anon->get_ok('/api/auth/sso/status')
      ->status_is(200)
      ->json_is('/enabled' => Mojo::JSON::false);
};

subtest 'GET /api/auth/me carries k8s_mode for anonymous and signed-in callers' => sub {
    my $anon = Test::Mojo->new($app);
    $anon->get_ok('/api/auth/me')->status_is(200)
      ->json_is('/authenticated' => 0)
      ->json_is('/k8s_mode' => Mojo::JSON::false);

    $t->get_ok('/api/auth/me')->status_is(200)
      ->json_is('/authenticated' => 1)
      ->json_is('/k8s_mode' => Mojo::JSON::false);

    local $ENV{KUBERNETES_SERVICE_HOST} = '10.0.0.1';
    $anon->get_ok('/api/auth/me')->json_is('/k8s_mode' => Mojo::JSON::true);
    $t->get_ok('/api/auth/me')->json_is('/k8s_mode' => Mojo::JSON::true);
};

done_testing;

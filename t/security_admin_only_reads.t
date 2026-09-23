#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);

# ============================================
# REGRESSION: authz holes left behind when the license feature gates went.
#
# Several READ endpoints had no role check of their own — the feature gate was
# the only thing in front of them. With the gates gone (#77) any viewer, and
# any holder of an ingest X-API-Key, could:
#   * list and DOWNLOAD full backups (including audit_logs), and read the
#     backup schedule and S3 config,
#   * read the LDAP and SSO/SAML configuration,
#   * list users and API keys,
#   * spend the LLM budget through /api/ai/{query,analyze,explain}.
# Pinned here against the real app: viewer session => 403, API key => 403,
# admin session => allowed; a viewer WITH a session may still use AI.
# ============================================

my $DIR;
BEGIN {
    $DIR = "/tmp/purl_admin_reads_test_$$";
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_API_KEYS}        = 'reads-ingest-key';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'admin-reads-test-secret-abcdef0123456789';
    $ENV{PURL_CONFIG_FILE}     = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}      = $DIR;
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
}
make_path($DIR);
END { remove_tree($DIR) if $DIR }

{
    package Purl::Storage::InMemory;
    use Moo;
    sub flush        { 1 }
    sub maybe_flush  { }
    sub get_metrics  { { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 } }
    sub log_audit_event    { 1 }
    sub _init_audit_schema { 1 }
    sub list_backups       { [ { id => 'b1' } ] }
    sub get_audit_logs     { [] }
    sub count_audit_logs   { 0 }
    sub get_audit_stats    { {} }
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

sub login {
    my ($user, $pass) = @_;
    my $t = Test::Mojo->new($app);
    $t->post_ok('/api/auth/login', { 'Content-Type' => 'application/json' },
        json => { username => $user, password => $pass })
      ->status_is(200)
      ->json_is('/authenticated' => 1);
    return $t;
}

sub csrf {
    my ($t) = @_;
    $t->get_ok('/api/csrf-token');
    return $t->tx->res->json->{csrf_token};
}

my $admin = login('admin', 'StrongAdminPass123');
$admin->post_ok('/api/settings/users',
    { 'Content-Type' => 'application/json', 'X-CSRF-Token' => csrf($admin) },
    json => { username => 'vic', password => 'ViewerPass12345', role => 'viewer' })
  ->status_is(200);
my $viewer = login('vic', 'ViewerPass12345');

my @ADMIN_ONLY_READS = qw(
    /api/backup
    /api/backup/b1/download
    /api/backup/schedule
    /api/backup/s3
    /api/settings/ldap
    /api/settings/sso
    /api/settings/users
    /api/settings/api-keys
    /api/audit
    /api/audit/stats
);

my %KEY = ('X-API-Key' => 'reads-ingest-key');

for my $path (@ADMIN_ONLY_READS) {
    subtest "GET $path is admin-only" => sub {
        $viewer->get_ok($path)->status_is(403, 'viewer session refused');
        Test::Mojo->new($app)->get_ok($path, \%KEY)->status_is(403, 'API key refused');
    };
}

subtest 'admin can still read them' => sub {
    for my $path (grep { !m{/download$} } @ADMIN_ONLY_READS) {
        $admin->get_ok($path)->status_is(200, "admin: $path");
    }
};

# AI spends a paid LLM budget: a leaked ingest key must not reach it, but a
# signed-in user of any role may.
for my $ep (qw(/api/ai/query /api/ai/analyze /api/ai/explain)) {
    subtest "POST $ep needs a signed-in user" => sub {
        Test::Mojo->new($app)->post_ok($ep,
            { %KEY, 'Content-Type' => 'application/json' },
            json => { question => 'errors today', logs => [], log => {} })
          ->status_is(403, 'API key refused')
          ->json_like('/error' => qr/signed-in user/);

        $viewer->post_ok($ep,
            { 'Content-Type' => 'application/json', 'X-CSRF-Token' => csrf($viewer) },
            json => { question => 'errors today', logs => [], log => {} });
        isnt $viewer->tx->res->code, 403, 'viewer session is not refused';
    };
}

done_testing;

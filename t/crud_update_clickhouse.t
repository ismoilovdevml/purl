#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use File::Temp qw(tempdir);
use Mojo::JSON qw(encode_json);

# ============================================
# #114 — every dashboard update returned 500: update_dashboard re-inserted
# get_dashboard's display string '2026-09-23T18:52:44Z' into a DateTime
# column, which ClickHouse 25.11 refuses. update_pipeline had the same line.
#
# REAL ClickHouse: the bug is what ClickHouse accepts, so a mock would pass it.
# Covers create -> update -> read back (storage and HTTP API), that created_at
# survives an update unchanged, and non-ASCII names/widgets (#113 on the CRUD
# path: JSON embedded in SQL must not be UTF-8 encoded twice).
#
# Own throwaway database (purl_t114_<pid>), dropped at the end.
# ============================================

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
);
my $db = "purl_t114_$$";

my $http = HTTP::Tiny->new(timeout => 30);
my $base = sprintf('http://%s:%d/?user=%s&password=%s',
    $conn{host}, $conn{port}, $conn{username}, $conn{password});

sub ch {
    my ($sql) = @_;
    my $res = $http->post($base, { content => $sql });
    die "ClickHouse: $res->{status} $res->{content}\n" unless $res->{success};
    my $out = $res->{content};
    chomp $out;
    return $out;
}

unless (eval { ch('SELECT 1') eq '1' }) {
    plan skip_all =>
        "No reachable ClickHouse at $conn{host}:$conn{port}. Dashboard/pipeline update (#114) "
      . "is therefore UNVERIFIED in this run. Set PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD to a "
      . "live (throwaway) instance to run it.";
}

END { eval { ch("DROP DATABASE IF EXISTS $db SYNC") } if $db; }

my $cfg_dir = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_DIR}   = $cfg_dir;
$ENV{PURL_CONFIG_FILE}  = "$cfg_dir/settings.json";
# Auth ON with a known admin: dashboard writes require the operator/admin
# role, so the API subtest drives them the way the UI does (session + CSRF).
$ENV{PURL_AUTH_ENABLED}   = 1;
$ENV{PURL_ADMIN_PASSWORD} = 'StrongAdminPass123';
$ENV{PURL_SESSION_SECRET} = 't114-session-secret-0123456789abcdef';
$ENV{PURL_LDAP_ENABLED}   = 0;
$ENV{PURL_SAML_ENABLED}   = 0;

require Purl::Storage::ClickHouse;
my $storage = Purl::Storage::ClickHouse->new(%conn, database => $db, durable => 1);
# The server creates these at boot (Bootstrap::init_schemas); do the same.
$storage->_init_dashboard_schema;
$storage->_init_pipeline_schema;

sub find_by_name {
    my ($list, $name) = @_;
    my ($row) = grep { $_->{name} eq $name } @$list;
    return $row;
}

# --------------------------------------------
# 1. Dashboards, storage layer
# --------------------------------------------
subtest 'dashboard create -> update -> get round-trips' => sub {
    $storage->create_dashboard({
        name    => 'qa-dash-repro',
        widgets => [ { type => 'counter', title => 'Ошибки' } ],
        layout  => { cols => 12 },
    });
    my $created = find_by_name($storage->list_dashboards, 'qa-dash-repro');
    ok $created, 'dashboard created' or return;
    my $id = $created->{id};

    # created_at must survive the update bit-for-bit; make sure a second
    # passes so a re-stamped created_at would be visible.
    sleep 1;

    my $res = eval { $storage->update_dashboard($id, {
        name    => 'qa-dash-repro2 日本',
        widgets => [ @{ $created->{widgets} }, { type => 'chart', title => '🚀 deploys' } ],
    }) };
    is $@, '', 'update_dashboard does not die (was: Cannot parse ... as DateTime)';
    is_deeply $res, { status => 'updated' }, 'update reports updated';

    my $got = $storage->get_dashboard($id);
    is $got->{name}, 'qa-dash-repro2 日本', 'new non-ASCII name read back';
    is scalar @{ $got->{widgets} }, 2, 'added widget is there after reload';
    is $got->{widgets}[0]{title}, 'Ошибки', 'Cyrillic widget title round-trips';
    is $got->{widgets}[1]{title}, '🚀 deploys', 'emoji widget title round-trips';
    is_deeply $got->{layout}, { cols => 12 }, 'untouched layout kept';
    is $got->{created_at}, $created->{created_at}, 'created_at unchanged by the update';
    ok $got->{updated_at} gt $created->{created_at}, 'updated_at moved forward';

    my $versions = ch("SELECT count() FROM $db.dashboards FINAL WHERE toString(id) = '$id'");
    is $versions, 1, 'FINAL collapses to one current row';
};

subtest 'dashboard update of an unknown id is undef, not an error' => sub {
    my $res = eval { $storage->update_dashboard('00000000-0000-0000-0000-000000000000', { name => 'x' }) };
    is $@, '', 'no exception';
    ok !defined $res, 'undef => controller answers 404';
    is ch("SELECT count() FROM $db.dashboards WHERE toString(id) = '00000000-0000-0000-0000-000000000000'"),
        0, 'nothing inserted for an unknown id';
};

# --------------------------------------------
# 2. Pipelines: same statement shape, same bug
# --------------------------------------------
subtest 'pipeline create -> update -> get round-trips' => sub {
    $storage->create_pipeline({ name => 'qa-pipe', rules => [ { type => 'drop', match => 'шум' } ] });
    my $created = find_by_name($storage->list_pipelines, 'qa-pipe');
    ok $created, 'pipeline created' or return;
    sleep 1;

    my $res = eval { $storage->update_pipeline($created->{id}, { name => 'qa-pipe-2', enabled => 1 }) };
    is $@, '', 'update_pipeline does not die';
    is_deeply $res, { status => 'updated' }, 'update reports updated';

    my $got = $storage->get_pipeline($created->{id});
    is $got->{name}, 'qa-pipe-2', 'new name read back';
    ok ${ $got->{enabled} }, 'enabled flag updated';
    is $got->{rules}[0]{match}, 'шум', 'Cyrillic rule round-trips';
    is $got->{created_at}, $created->{created_at}, 'created_at unchanged by the update';
};

# --------------------------------------------
# 2b. A name-only update keeps stored flags. They read back as \1 / \0, and a
#     reference is always true: every update used to switch them ON.
# --------------------------------------------
subtest 'name-only update keeps enabled=0 / shared=0' => sub {
    $storage->create_pipeline({ name => 'qa-pipe-off', enabled => 0 });
    my $p = find_by_name($storage->list_pipelines, 'qa-pipe-off');
    ok !${ $p->{enabled} }, 'pipeline created disabled';
    $storage->update_pipeline($p->{id}, { name => 'qa-pipe-off-2' });
    ok !${ $storage->get_pipeline($p->{id})->{enabled} }, 'still disabled after a name-only update';

    $storage->create_dashboard({ name => 'qa-dash-private', shared => 0 });
    my $d = find_by_name($storage->list_dashboards, 'qa-dash-private');
    ok !${ $d->{shared} }, 'dashboard created private';
    $storage->update_dashboard($d->{id}, { name => 'qa-dash-private-2' });
    ok !${ $storage->get_dashboard($d->{id})->{shared} }, 'still private after a name-only update';

    $storage->update_dashboard($d->{id}, { shared => 1 });
    ok ${ $storage->get_dashboard($d->{id})->{shared} }, 'an explicit shared=1 still turns it on';
};

subtest 'column names are identifiers only' => sub {
    ok !eval { $storage->_insert_crud_version("$db.dashboards", '0', { 'name) SELECT 1 --' => q{'x'} }); 1 },
        'a non-identifier column key dies';
    like $@, qr/Invalid column name/, 'with a clear message';
};

# --------------------------------------------
# 3. HTTP API: what the dashboard UI does (create, add widget, reload)
# --------------------------------------------
subtest 'API: POST -> PUT -> GET' => sub {
    require Purl::API::Server;
    {
        no warnings 'redefine';
        *Purl::API::Server::_build_storage = sub { return $storage };
    }
    my $app = Purl::API::Server->create(config => { auth => { enabled => 1 } })->setup_routes;
    $app->log->unsubscribe('message');

    require Test::Mojo;
    my $t = Test::Mojo->new($app);
    $t->post_ok('/api/auth/login' => json => { username => 'admin', password => 'StrongAdminPass123' })
      ->status_is(200);
    my $csrf = $t->get_ok('/api/csrf-token')->tx->res->json('/csrf_token');
    my %h = ('X-CSRF-Token' => $csrf);

    $t->post_ok('/api/dashboards' => \%h => json => { name => 'qa-api-dash' })->status_is(201);
    my ($row) = grep { $_->{name} eq 'qa-api-dash' }
        @{ $t->get_ok('/api/dashboards')->tx->res->json('/dashboards') // [] };
    ok $row, 'created dashboard listed' or return;

    $t->put_ok("/api/dashboards/$row->{id}" => \%h => json => {
        name    => 'qa-api-dash renamed',
        widgets => [ { type => 'counter', title => 'Errors' } ],
        created_at => '1999-01-01T00:00:00Z',   # a client echoing the field must not matter
    })->status_is(200, 'PUT is 200, not 500');

    $t->get_ok("/api/dashboards/$row->{id}")->status_is(200)
      ->json_is('/name', 'qa-api-dash renamed')
      ->json_is('/widgets/0/type', 'counter')
      ->json_is('/created_at', $row->{created_at}, 'created_at is server-managed');

    $t->put_ok('/api/dashboards/00000000-0000-0000-0000-000000000000' => \%h => json => { name => 'x' })
      ->status_is(404, 'unknown id is 404');
};

done_testing;

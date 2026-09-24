#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::KQL qw(parse_kql);

# ============================================
# #112 — the Kubernetes pickers are filters of their own, ANDed with the whole
# search expression. Appended to the query text, `a OR b cluster:x` meant
# `a OR (b AND cluster:x)`. The database-backed half is
# t/k8s_picker_filter_clickhouse.t.
# ============================================

{
    package PickCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    with 'Purl::Storage::ClickHouse::K8sColumns';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

my ($or) = parse_kql('level:ERROR OR level:WARN');

subtest 'storage: picker is ANDed with the whole expression' => sub {
    my ($sql, $bind) = PickCH->new->_build_where_clause(kql => $or, cluster => 'a');
    like $sql, qr/\AWHERE \(\(.+\) OR \(.+\)\) AND cluster = \{p_k8s_cluster:String\}\z/,
        'the OR is one parenthesised operand of the AND';
    is $bind->{p_k8s_cluster}, 'a', 'value bound, never interpolated';
};

subtest 'storage: every picker, wildcards escaped' => sub {
    my ($sql, $bind) = PickCH->new->_build_where_clause(
        kql => $or, cluster => 'a', namespace => 'shop', pod => 'web_*', container => 'app');
    like $sql, qr/ AND cluster = \{p_k8s_cluster:String\}/,        'cluster';
    like $sql, qr/ AND namespace = \{p_k8s_namespace:String\}/,    'namespace';
    like $sql, qr/ AND pod LIKE \{p_k8s_pod:String\}/,             'pod wildcard';
    like $sql, qr/ AND container = \{p_k8s_container:String\}/,    'container';
    is $bind->{p_k8s_pod}, 'web\\_%', 'LIKE metacharacters escaped';

    ($sql) = PickCH->new->_build_where_clause(cluster => '', pod => [ 'x' ]);
    is $sql, '', 'empty and non-scalar picker values are ignored';
};

# --------------------------------------------
# The endpoints the Logs page calls pass the pickers through to storage.
# --------------------------------------------
{
    package PickStorage;
    sub new    { return bless { calls => [] }, shift }
    sub search { my ($s, %p) = @_; push @{ $s->{calls} }, \%p; return [] }
    sub count  { return 0 }
    sub field_stats { my ($s, $f, %p) = @_; push @{ $s->{calls} }, \%p; return [] }
}

require Mojolicious;
require Test::Mojo;
require Purl::API::Controller::Logs;
require Purl::API::Controller::Stats;

my $storage = PickStorage->new;
my $app = Mojolicious->new;
$app->log->level('fatal');
my $logs  = Purl::API::Controller::Logs->new(storage => $storage);
my $stats = Purl::API::Controller::Stats->new(storage => $storage);
$app->routes->get('/api/logs' => sub { $logs->search(shift) });
$app->routes->get('/api/stats/fields/:field' => sub { my $c = shift; $c->param(field => $c->stash('field')); $stats->field_stats($c) });
my $t = Test::Mojo->new($app);

$t->get_ok('/api/logs?q=level:ERROR%20OR%20level:WARN&cluster=a&namespace=shop&pod=p&container=c')->status_is(200);
my $got = $storage->{calls}[-1];
is_deeply [ @{$got}{qw(cluster namespace pod container)} ], [ qw(a shop p c) ], 'GET /api/logs passes every picker';
is $got->{kql}{op}, 'or', 'the query itself is untouched';

$t->get_ok('/api/stats/fields/level?q=level:ERROR%20OR%20level:WARN&cluster=a')->status_is(200);
is $storage->{calls}[-1]{cluster}, 'a', 'GET /api/stats/fields/:field passes the picker (facets match the list)';

$t->get_ok('/api/logs?q=x&cluster=')->status_is(200);
ok !exists $storage->{calls}[-1]{cluster}, 'an empty picker is no filter';

done_testing;

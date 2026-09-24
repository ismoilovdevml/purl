#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);

# ============================================
# #115: every log-ingest endpoint answers 503 + Retry-After when the bounded
# ingest buffer cannot take the batch, and inserts nothing. Driven through the
# real routes of the app; storage is a stand-in that reports a full buffer.
# (JSON/NDJSON: t/ingest_backpressure.t, K8s audit: t/k8s_audit.t.)
# ============================================

my $dir = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_DIR}      = $dir;
$ENV{PURL_CONFIG_FILE}     = "$dir/settings.json";
$ENV{PURL_AUTH_ENABLED}    = 0;
$ENV{PURL_LDAP_ENABLED}    = 0;
$ENV{PURL_SAML_ENABLED}    = 0;
$ENV{PURL_SESSION_SECRET}  = 'backpressure-test-secret-0123456789abcdef';
$ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
$ENV{PURL_CLICKHOUSE_PORT} = '19999';

{
    package FullStorage;
    use Moo;
    has full     => (is => 'rw', default => 1);
    has inserted => (is => 'rw', default => sub { [] });
    sub buffer_full  { $_[0]->full }
    sub durable      { 0 }
    sub insert       { push @{ $_[0]->inserted }, $_[1]; 1 }
    sub insert_batch { push @{ $_[0]->inserted }, @{ $_[1] }; scalar @{ $_[1] } }
    sub flush        { 0 }
    sub maybe_flush  { 0 }
    sub list_pipelines { [] }
    sub get_metrics  { {} }
}

my $storage = FullStorage->new;
require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { $storage };
}
my $app = Purl::API::Server->create(config => { auth => { enabled => 0 } })->setup_routes;
$app->log->unsubscribe('message');

require Test::Mojo;
my $t = Test::Mojo->new($app);

my %requests = (
    OTLP => [ '/api/v1/otlp/logs', json => { resourceLogs => [ {
        resource  => { attributes => [ { key => 'service.name', value => { stringValue => 'svc' } } ] },
        scopeLogs => [ { logRecords => [ { body => { stringValue => 'hello' }, severityText => 'INFO' } ] } ],
    } ] } ],
    Syslog => [ '/api/v1/syslog', json => { messages => [ '<14>1 2026-09-23T18:00:00Z host app 1 - - hello' ] } ],
);

for my $name (sort keys %requests) {
    my ($path, @body) = @{ $requests{$name} };

    $storage->full(1);
    $storage->inserted([]);
    $t->post_ok($path => @body)
      ->status_is(503, "$name: buffer full => 503")
      ->header_is('Retry-After' => '1', "$name: Retry-After: 1");
    is scalar @{ $storage->inserted }, 0, "$name: nothing inserted";

    # Control: the same request is accepted when there is room, so the 503
    # above really is the backpressure check and not a malformed payload.
    $storage->full(0);
    $t->post_ok($path => @body)->status_is(200, "$name: accepted when the buffer has room");
    ok scalar @{ $storage->inserted }, "$name: inserted when accepted";
}

done_testing;

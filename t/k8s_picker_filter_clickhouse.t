#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

use Time::HiRes qw(time);
use POSIX qw(strftime);
use URI::Escape qw(uri_escape);
use File::Temp qw(tempdir);
use PurlTest::ClickHouse qw(ch_connect);

# ============================================
# #112 — the cluster picker was appended to the search text, so
#   `level:ERROR OR level:WARN meta.cluster:a`
# ran as `level:ERROR OR (level:WARN AND cluster a)` and returned cluster b's
# errors. The pickers (cluster, namespace, pod, container) are now separate
# request parameters, ANDed with the WHOLE search expression.
#
# REAL ClickHouse: what matters is which rows come back.
# ============================================

my ($conn, $ch, $db) = ch_connect('purl_t112', 'Picker filter grouping (#112)');

$ENV{PURL_CONFIG_DIR}   = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_FILE}  = "$ENV{PURL_CONFIG_DIR}/settings.json";
$ENV{PURL_AUTH_ENABLED} = 0;
$ENV{MOJO_LOG_LEVEL}    = 'fatal';

require Purl::Storage::ClickHouse;
my $storage = Purl::Storage::ClickHouse->new(
    %$conn, database => $db, durable => 1, use_query_cache => 0,
);

my $now = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() - 30));
my @rows = (
    # cluster, namespace, pod,     container, level
    [ 'a', 'shop', 'web-1',  'app',   'ERROR' ],
    [ 'a', 'shop', 'web-2',  'app',   'WARN'  ],
    [ 'a', 'shop', 'web-3',  'app',   'INFO'  ],
    [ 'b', 'shop', 'web-9',  'app',   'ERROR' ],
    [ 'b', 'shop', 'web-8',  'app',   'WARN'  ],
    [ 'a', 'ops',  'job-1',  'sidecar', 'ERROR' ],
);
for my $r (@rows) {
    my ($cluster, $ns, $pod, $cont, $level) = @$r;
    $storage->insert({ level => $level, service => 't112', host => 'h', timestamp => $now,
        message => "t112 $pod", meta => { cluster => $cluster, namespace => $ns, pod => $pod, container => $cont } });
}
is $storage->flush, scalar @rows, 'rows flushed to real ClickHouse';

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}
my $app = Purl::API::Server->create(config => { auth => { enabled => 0 } })->setup_routes;
$app->log->unsubscribe('message');
require Test::Mojo;
my $t = Test::Mojo->new($app);

my $or = uri_escape('level:ERROR OR level:WARN');

sub pods {
    my ($query) = @_;
    $t->get_ok("/api/logs?range=1h&limit=50&$query")->status_is(200, "GET /api/logs?$query");
    return [ sort map { $_->{meta}{pod} } @{ $t->tx->res->json('/hits') // [] } ];
}

is_deeply pods("q=$or"), [ qw(job-1 web-1 web-2 web-8 web-9) ], 'the OR query alone: both clusters';
is_deeply pods("q=$or&cluster=a"), [ qw(job-1 web-1 web-2) ],
    'cluster=a is ANDed with the whole OR, not only its last term';
is $t->tx->res->json('/total'), 3, 'total counts the same rows';

is_deeply pods("q=$or&namespace=shop"), [ qw(web-1 web-2 web-8 web-9) ], 'namespace picker groups the same way';
is_deeply pods("q=$or&cluster=a&namespace=shop"), [ qw(web-1 web-2) ], 'pickers combine with AND';
is_deeply pods("q=$or&container=sidecar"), [ 'job-1' ], 'container picker';
is_deeply pods("q=$or&pod=web-*&cluster=b"), [ qw(web-8 web-9) ], 'pod picker with a wildcard';
is_deeply pods('cluster=a'), [ qw(job-1 web-1 web-2 web-3) ], 'a picker without a query';
is_deeply pods(q{cluster=} . uri_escape(q{a' OR '1'='1})), [], 'injection string as a cluster => 0 rows';

# The facets the Logs page shows next to the list describe the same rows.
$t->get_ok("/api/stats/fields/level?range=1h&q=$or&cluster=a")->status_is(200);
is_deeply { map { $_->{value} => $_->{count} } @{ $t->tx->res->json('/values') // [] } },
    { ERROR => 2, WARN => 1 }, 'level facet with cluster=a counts only cluster a';

done_testing;

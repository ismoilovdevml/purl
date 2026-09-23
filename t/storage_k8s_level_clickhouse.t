#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use Time::HiRes qw(time sleep);
use POSIX qw(strftime);
use Purl::Storage::ClickHouse;
use Purl::Util::KQL qw(parse_kql);

# ============================================
# REAL ClickHouse test for #104 (k8s columns) and #105 (level case).
#
# Not mocked: the point is what ClickHouse does with the migration, the
# materialized columns and upper(level) on rows written by an OLDER Purl.
#
# Uses its own throwaway database (purl_t104_<pid>) and drops it at the end.
# Connection from PURL_CLICKHOUSE_* like the app; skipped — loudly — when no
# ClickHouse is reachable, never faked.
# ============================================

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
);
my $db = "purl_t104_$$";

my $http = HTTP::Tiny->new(timeout => 30);
my $base = sprintf('http://%s:%d/?user=%s&password=%s',
    $conn{host}, $conn{port}, $conn{username}, $conn{password});

sub ch {
    my ($sql) = @_;
    my $res = $http->post($base, { content => $sql });
    die "ClickHouse: $res->{status} $res->{content}\n  SQL: $sql\n" unless $res->{success};
    my $out = $res->{content};
    chomp $out;
    return $out;
}

unless (eval { ch('SELECT 1') eq '1' }) {
    plan skip_all =>
        "No reachable ClickHouse at $conn{host}:$conn{port}. The #104/#105 migration and "
      . "query behaviour is therefore UNVERIFIED in this run. Set PURL_CLICKHOUSE_HOST/PORT/"
      . "USER/PASSWORD to a live (throwaway) instance to run it.";
}

END { eval { ch("DROP DATABASE IF EXISTS $db SYNC") } if $db; }

sub ts_ago { strftime('%Y-%m-%d %H:%M:%S', gmtime(time() - $_[0])) }

sub new_storage {
    return Purl::Storage::ClickHouse->new(
        %conn, database => $db, durable => 1, use_query_cache => 0,
    );
}

sub wait_mutations_done {
    for (1 .. 60) {
        return 1 if ch("SELECT count() FROM system.mutations WHERE database='$db' AND table='logs' AND NOT is_done") eq '0';
        sleep 0.5;
    }
    return 0;
}

sub mutation_count {
    return ch("SELECT count() FROM system.mutations WHERE database='$db' AND table='logs'");
}

# --------------------------------------------
# 1. A logs table as an OLDER Purl created it: no k8s columns, and rows whose
#    level case and meta encoding came from un-normalised shippers.
# --------------------------------------------
ch("CREATE DATABASE $db");
ch(qq{
    CREATE TABLE $db.logs (
        id UUID DEFAULT generateUUIDv4(),
        timestamp DateTime64(3),
        level LowCardinality(String),
        service LowCardinality(String),
        host LowCardinality(String),
        message String,
        raw String,
        meta String,
        trace_id String DEFAULT '',
        request_id String DEFAULT '',
        span_id String DEFAULT '',
        parent_span_id String DEFAULT ''
    ) ENGINE = MergeTree() PARTITION BY toYYYYMMDD(timestamp)
      ORDER BY (service, level, timestamp)
});

my $now = ts_ago(60);
my $old = ts_ago(3 * 86400);
my $k8s = sub {
    my ($ns, $pod, $cont) = @_;
    return qq({"namespace":"$ns","pod":"$pod","container":"$cont","node":"node-a"});
};
my @legacy = (
    [ $now, 'warn', 'api', $k8s->('trk', 'api-7d9-x1', 'app') ],
    [ $now, 'WARN', 'api', $k8s->('trk', 'api-7d9-x2', 'app') ],
    [ $now, 'info', 'api', $k8s->('trk', 'api-7d9-x1', 'istio-proxy') ],
    [ $now, 'INFO', 'web', $k8s->('shop', 'web-55-a', 'app') ],
    [ $now, 'INFO', 'vm',  '{}' ],                     # non-k8s row
    [ $old, 'INFO', 'web', $k8s->('archive', 'web-1', 'app') ],
);
my $values = join ', ', map {
    my ($t, $l, $s, $m) = @$_;
    $m =~ s/\\/\\\\/g; $m =~ s/'/\\'/g;
    "('$t', '$l', '$s', 'h1', 'legacy', '', '$m')";
} @legacy;
ch("INSERT INTO $db.logs (timestamp, level, service, host, message, raw, meta) VALUES $values");
# Double-encoded meta (a JSON string holding JSON), as Purl stored it before the
# ingest API started decoding string meta.
ch(q{INSERT INTO } . $db . q{.logs (timestamp, level, service, host, message, raw, meta) VALUES ('}
    . $now . q{', 'Error', 'legacy-enc', 'h1', 'legacy', '', '"{\\\\"namespace\\\\":\\\\"enc-ns\\\\",\\\\"pod\\\\":\\\\"enc-pod\\\\"}"')});
like ch("SELECT meta FROM $db.logs WHERE service='legacy-enc' FORMAT TSVRaw"), qr/\A"\{\\"namespace/, 'fixture: double-encoded meta row stored';

# --------------------------------------------
# 2. Migration: constructing storage upgrades the table in place.
# --------------------------------------------
my $storage = new_storage();

my %kind = map { split /\t/ } split /\n/,
    ch("SELECT name, default_kind FROM system.columns WHERE database='$db' AND table='logs' AND name IN ('namespace','pod','container')");
is_deeply \%kind, { namespace => 'MATERIALIZED', pod => 'MATERIALIZED', container => 'MATERIALIZED' },
    'namespace/pod/container added as MATERIALIZED columns';

ok wait_mutations_done(), 'backfill mutation for existing parts finished';
my $mutations = mutation_count();
cmp_ok $mutations, '>=', 1, 'existing parts were backfilled by a MATERIALIZE COLUMN mutation';

is ch("SELECT groupArray(namespace) FROM (SELECT namespace FROM $db.logs WHERE message='legacy' ORDER BY service, pod)"),
   q{['trk','trk','trk','enc-ns','','archive','shop']}, 'legacy rows (incl. double-encoded meta) backfilled'
   or diag ch("SELECT service, pod, namespace FROM $db.logs");

new_storage();
new_storage();
is mutation_count(), $mutations, 'a restart does not re-run the backfill (idempotent)';

# --------------------------------------------
# 3. New rows through the real ingest path.
# --------------------------------------------
my $iso_now = ts_ago(30) =~ s/ /T/r . 'Z';    # the ingest controllers always set a UTC timestamp
$storage->insert({ level => 'warn',  service => 'api', timestamp => $iso_now, host => 'h2', message => 'new',
                   meta => { namespace => 'trk', pod => 'api-7d9-x3', container => 'app', node => 'node-b' } });
$storage->insert({ level => 'Info ', service => 'api', timestamp => $iso_now, host => 'h2', message => 'new',
                   meta => { namespace => 'trk', pod => 'worker-1', container => 'app', node => 'node-b' } });
$storage->flush;

is ch("SELECT groupUniqArray(level) FROM $db.logs WHERE message='new'"), "['WARN','INFO']",
    'ingest stored canonical upper-case levels'
    or diag ch("SELECT level FROM $db.logs WHERE message='new'");
is ch("SELECT count() FROM $db.logs WHERE message='new' AND namespace='trk' AND pod != ''"), '2',
    'new rows get namespace/pod on insert';

my %range = (from => ts_ago(3600) =~ s/ /T/r . 'Z', to => ts_ago(-60) =~ s/ /T/r . 'Z');

sub kql { my ($q) = @_; my ($ast, $err) = parse_kql($q); die $err if $err; return (kql => $ast) }
sub facet { my ($f, %p) = @_; return { map { $_->{value} => $_->{count} } @{ $storage->field_stats($f, limit => 50, %p) } } }

# --------------------------------------------
# 4. #105 — mixed-case rows are one level.
# --------------------------------------------
is $storage->count(kql('level:warn'), %range), 3, 'level:warn matches legacy warn + WARN + new';
is $storage->count(kql('level:WARN'), %range), 3, 'level:WARN is the same filter';
is $storage->count(level => 'info', %range), 4, 'flat level param matches every case';
is_deeply facet('level', %range), { WARN => 3, INFO => 4, ERROR => 1 },
    'level facet has one bucket per level, no lower-case duplicates';

my $hist = $storage->histogram(interval => '1 day', %range);
my $w = 0;
$w += $_->{warnings} // 0 for @$hist;
is $w, 3, 'histogram counts WARN (any case) as warnings';

# --------------------------------------------
# 5. #104 — k8s search and facets.
# --------------------------------------------
is $storage->count(kql('namespace:trk'), %range), 5, 'namespace:trk';
is $storage->count(kql('pod:api-7d9-*'), %range), 4, 'pod:x* wildcard';
is $storage->count(kql('namespace:trk AND NOT container:istio-proxy'), %range), 4, 'AND NOT';
is $storage->count(kql('namespace:shop OR namespace:enc-ns'), %range), 2, 'OR (incl. legacy-encoded row)';
is $storage->count(kql('namespace:tr'), %range), 0, 'equality, not substring';

is_deeply facet('namespace', %range), { trk => 5, shop => 1, 'enc-ns' => 1 },
    'namespace facet: time range applied, rows without a namespace left out';
is_deeply facet('namespace', %range, kql('service:web')), { shop => 1 },
    'namespace facet respects the current query';
is_deeply facet('container', %range, kql('namespace:trk')), { app => 4, 'istio-proxy' => 1 },
    'container facet';
is_deeply facet('pod', %range, kql('namespace:trk AND level:warn')),
    { 'api-7d9-x1' => 1, 'api-7d9-x2' => 1, 'api-7d9-x3' => 1 }, 'pod facet with a level filter';
is_deeply facet('namespace', kql('service:web')), { shop => 1, archive => 1 },
    'without a time range the 3-day-old row is counted';

my $rows = $storage->field_stats('pod', limit => 1, %range);
is scalar @$rows, 1, 'limit honoured';
is_deeply [ sort keys %{ $rows->[0] } ], [ 'count', 'value' ], 'same {value,count} shape as host';

# meta.* facets were silently empty: the query assumed every meta was
# double-encoded and stripped/unescaped it, turning valid JSON into garbage.
is_deeply facet('meta.node', %range), { 'node-a' => 4, 'node-b' => 2 },
    'meta.<key> facet reads plain JSON meta (was always empty)';

# The search API returns the same rows, meta decoded.
my $hits = $storage->search(kql('namespace:trk AND pod:worker-*'), %range, limit => 10);
is scalar @$hits, 1, 'search() with a k8s filter';
is $hits->[0]{meta}{pod}, 'worker-1', 'row meta intact';

done_testing;

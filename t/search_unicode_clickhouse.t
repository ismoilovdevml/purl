#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use HTTP::Tiny;
use URI::Escape qw(uri_escape_utf8);
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);

binmode(Test::More->builder->$_, ':encoding(UTF-8)') for qw(output failure_output todo_output);

# ============================================
# #113 — searching for text above U+00FF (Cyrillic, CJK, emoji) returned 500
# "Wide character in subroutine entry" (Cache.pm md5_hex on a character
# string), and text between U+0080 and U+00FF (café) "worked" only by sending
# Latin-1 bytes to ClickHouse, so it matched nothing stored as UTF-8.
#
# REAL ClickHouse, not mocked: the point is that the bytes reaching ClickHouse
# are the UTF-8 of what the user typed, so the rows that contain it come back —
# a 200 with zero hits would hide the Latin-1 half of the bug.
#
# Own throwaway database (purl_t113_<pid>), dropped at the end. Skipped —
# loudly — when no ClickHouse is reachable.
# ============================================

my %conn = (
    host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
    username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
    password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
);
my $db = "purl_t113_$$";

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
        "No reachable ClickHouse at $conn{host}:$conn{port}. Non-ASCII search (#113) is "
      . "therefore UNVERIFIED in this run. Set PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD to a "
      . "live (throwaway) instance to run it.";
}

my $cfg_dir = tempdir(CLEANUP => 1);
END { eval { ch("DROP DATABASE IF EXISTS $db SYNC") } if $db; }

$ENV{PURL_CONFIG_DIR}  = $cfg_dir;
$ENV{PURL_CONFIG_FILE} = "$cfg_dir/settings.json";
$ENV{PURL_AUTH_ENABLED} = 0;

require Purl::Storage::ClickHouse;

# Query cache ON: the crash was in the cache-key hash, so the test must go
# through it.
my $storage = Purl::Storage::ClickHouse->new(
    %conn, database => $db, durable => 1, use_query_cache => 1,
);

my %texts = (
    cyrillic => 'ошибка подключения к базе',
    cjk      => '日本語のログメッセージ',
    emoji    => 'deploy finished ✓ 🚀',
    latin1   => 'café au lait',
);

for my $kind (sort keys %texts) {
    $storage->insert({
        level   => 'ERROR',
        service => "t113-$kind",
        host    => 'test-host',
        message => "$texts{$kind} [$kind]",
        meta    => { team => 'команда', kind => $kind },
    });
}
$storage->insert({ level => 'INFO', service => 't113-ascii', host => 'test-host',
    message => 'plain ascii line', meta => {} });
is $storage->flush, 5, 'five rows flushed (durable) to real ClickHouse';
# range=1h in the API becomes to=<now, whole seconds>: let the rows' own
# (millisecond) second pass so they fall inside it.
select(undef, undef, undef, 1.1);

# --------------------------------------------
# 1. Storage layer: the literal text search binds the term as a parameter.
# --------------------------------------------
my %needle = (
    cyrillic => 'ошибка',
    cjk      => '日本語',
    emoji    => '🚀',
    latin1   => 'café',
);

for my $kind (sort keys %needle) {
    for my $pass (1, 2) {   # second pass is served from the query cache
        my $rows = eval { $storage->search(query => $needle{$kind}, range => '1h', limit => 10) };
        is $@, '', "$kind search (pass $pass) does not die";
        is scalar(@{ $rows // [] }), 1, "$kind search (pass $pass) finds exactly its row";
        is $rows->[0]{service}, "t113-$kind", "$kind search (pass $pass) returns the right row"
            if $rows && @$rows;
        is $rows->[0]{message}, "$texts{$kind} [$kind]",
            "$kind message round-trips as the same characters (pass $pass)"
            if $rows && @$rows;
        # A cache hit used to return the cache's own rows already rewritten by
        # the first call: timestamp undef, meta {}.
        ok defined($rows->[0]{timestamp}), "$kind row has its timestamp (pass $pass)"
            if $rows && @$rows;
        is $rows->[0]{meta}{kind}, $kind, "$kind row has its meta (pass $pass)"
            if $rows && @$rows;
    }
}

# Meta written by Purl is UTF-8 text in ClickHouse, not UTF-8 encoded twice:
# a meta.* KQL filter is a substring match on the stored JSON.
{
    my $stored = ch("SELECT meta FROM $db.logs WHERE service = 't113-cyrillic'");
    utf8::decode($stored);
    like $stored, qr/команда/, 'meta is stored as single-encoded UTF-8 (readable in ClickHouse)';

    my $rows = $storage->search(query => 'ошибка', range => '1h', limit => 10);
    my $got  = $rows && @$rows ? $rows->[0]{meta}{team} : undef;
    is $got, 'команда', 'meta with non-ASCII values round-trips back to the API';
}

# --------------------------------------------
# 2. The HTTP API the Logs page calls: GET /api/logs?q=...
# --------------------------------------------
require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}
my $app = Purl::API::Server->create(config => { auth => { enabled => 0 } })->setup_routes;
$app->log->unsubscribe('message');

require Test::Mojo;
my $t = Test::Mojo->new($app);

for my $kind (sort keys %needle) {
    my $q = uri_escape_utf8($needle{$kind});
    $t->get_ok("/api/logs?limit=10&range=1h&q=$q")
      ->status_is(200, "GET /api/logs q=$kind is 200, not 500 'Wide character'");
    my $hits = $t->tx->res->json('/hits') // [];
    is scalar(@$hits), 1, "GET /api/logs q=$kind returns its row";
    is $hits->[0]{service}, "t113-$kind", "GET /api/logs q=$kind returns the right row" if @$hits;
}

# KQL path (the search bar sends field:value queries too).
{
    my $q = uri_escape_utf8('message:ошибка');
    $t->get_ok("/api/logs?limit=10&range=1h&q=$q")->status_is(200, 'KQL message:<cyrillic> is 200');
    my $hits = $t->tx->res->json('/hits') // [];
    is scalar(@$hits), 1, 'KQL message:<cyrillic> finds its row';

    # meta.* is a substring match on the stored JSON: only works when meta is
    # stored as UTF-8 once (it used to be encoded twice).
    $q = uri_escape_utf8('meta.team:команда');
    $t->get_ok("/api/logs?limit=10&range=1h&q=$q")->status_is(200, 'KQL meta.team:<cyrillic> is 200');
    $hits = $t->tx->res->json('/hits') // [];
    is scalar(@$hits), 4, 'KQL meta.team:<cyrillic> finds the four rows carrying it';
}

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

use Time::HiRes qw(time);
use POSIX qw(strftime);
use File::Temp qw(tempdir);
use PurlTest::ClickHouse qw(ch_connect);

# ============================================
# #110 — WARN and WARNING were two level values.
#
# REAL ClickHouse: the point is which stored rows a level filter, facet,
# pattern list and histogram see, including rows written before ingest folded
# synonyms together (they cannot be rewritten: `level` is a sort key).
#
#   1. every ingest path stores the canonical name (JSON API, OTLP, syslog);
#   2. a filter on the canonical name (or on any synonym) matches old rows
#      stored under a synonym, in any case;
#   3. the level facet has one bucket per canonical level.
# ============================================

my ($conn, $ch, $db) = ch_connect('purl_t110', 'Level synonym folding (#110)');

$ENV{PURL_CONFIG_DIR}   = tempdir(CLEANUP => 1);
$ENV{PURL_CONFIG_FILE}  = "$ENV{PURL_CONFIG_DIR}/settings.json";
$ENV{PURL_AUTH_ENABLED} = 0;
$ENV{MOJO_LOG_LEVEL}    = "fatal";

require Purl::Storage::ClickHouse;
require Purl::Util::KQL;

my $storage = Purl::Storage::ClickHouse->new(
    %$conn, database => $db, durable => 1, use_query_cache => 0,
);

sub ts_ago { strftime('%Y-%m-%d %H:%M:%S', gmtime(time() - $_[0])) }

# --------------------------------------------
# 1. Rows an older Purl stored as they arrived.
# --------------------------------------------
my @legacy = qw(WARNING warning Warn ERR err crit CRITICAL EMERGENCY ALERT PANIC FATAL NOTICE);
my $then = ts_ago(120);
$ch->("INSERT INTO $db.logs (timestamp, level, service, host, message, raw, meta) VALUES "
    . join(', ', map { "('$then', '$_', 't110-legacy', 'h', 't110 legacy $_', '', '{}')" } @legacy));
# One message stored twice: once as an older Purl wrote it (WARNING), once as
# ingest writes it now (WARN). It is one pattern, not two.
$ch->("INSERT INTO $db.logs (timestamp, level, service, host, message, raw, meta) VALUES "
    . "('$then', 'WARNING', 'p110-pattern', 'h', 'disk almost full on vol 7', '', '{}')");
$storage->insert({ level => 'WARN', service => 'p110-pattern', host => 'h', message => 'disk almost full on vol 9' });
$storage->flush;

# --------------------------------------------
# 2. New rows through each ingest path's HTTP endpoint.
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

$t->post_ok('/api/logs' => json => [
    map { { level => $_, service => 't110-json', host => 'h', message => "t110 json $_" } }
        qw(WARNING err Critical notice)
])->status_is(200, 'JSON ingest accepted');

my $otlp_record = sub {
    my (%r) = @_;
    return { timeUnixNano => int(time() * 1e9) . '', body => { stringValue => 't110 otlp' }, %r };
};
$t->post_ok('/api/v1/otlp/logs' => json => { resourceLogs => [ {
    resource  => { attributes => [ { key => 'service.name', value => { stringValue => 't110-otlp' } } ] },
    scopeLogs => [ { logRecords => [
        $otlp_record->(severityText => 'WARNING'),
        $otlp_record->(severityText => 'crit'),
        $otlp_record->(severityNumber => 13),
    ] } ],
} ] })->status_is(200, 'OTLP ingest accepted');

# PRI = facility(1, user) * 8 + severity: 4 warning, 2 crit, 5 notice, 3 err, 0 emerg.
my $stamp = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
$t->post_ok('/api/v1/syslog' => json => { messages => [
    map { "<$_>1 $stamp h t110-syslog - - - t110 syslog $_" } 12, 10, 13, 11, 8
] })->status_is(200, 'syslog ingest accepted');

$storage->flush;

sub stored {
    my ($service) = @_;
    return [ sort split /,/, $ch->("SELECT arrayStringConcat(groupArray(level), ',') FROM $db.logs WHERE service = '$service'") ];
}
is_deeply stored('t110-json'),   [ sort qw(WARN ERROR FATAL INFO) ],      'JSON API stores canonical names';
is_deeply stored('t110-otlp'),   [ sort qw(WARN FATAL WARN) ],            'OTLP stores canonical names';
is_deeply stored('t110-syslog'), [ sort qw(WARN FATAL INFO ERROR FATAL) ], 'syslog stores canonical names';

# --------------------------------------------
# 3. Queries see every spelling of a level.
# --------------------------------------------
my %range = (from => ts_ago(3600) =~ s/ /T/r . 'Z', to => ts_ago(-60) =~ s/ /T/r . 'Z');
sub kql {
    my ($q) = @_;
    my ($ast, $err) = Purl::Util::KQL::parse_kql($q);
    die $err if $err;
    return (kql => $ast);
}
my %all = kql('service:t110-*');

# WARN: legacy WARNING/warning/Warn + JSON 1 + OTLP 2 + syslog 1.
my %expect = (WARN => 7, ERROR => 4, FATAL => 10, INFO => 3);

for my $level (sort keys %expect) {
    my ($ast) = Purl::Util::KQL::parse_kql("service:t110-* AND level:\L$level");
    is $storage->count(kql => $ast, %range), $expect{$level},
        "KQL level:\L$level\E matches every stored spelling ($expect{$level})";
    is $storage->count(%all, level => $level, %range), $expect{$level},
        "flat level=$level matches every stored spelling";
}

{
    my ($ast) = Purl::Util::KQL::parse_kql('service:t110-* AND level:WARNING');
    is $storage->count(kql => $ast, %range), $expect{WARN}, 'KQL level:WARNING is the same filter as level:WARN';
    is $storage->count(%all, level => 'crit', %range), $expect{FATAL}, 'flat level=crit is the same filter as FATAL';
}

is_deeply { map { $_->{value} => $_->{count} } @{ $storage->field_stats('level', %all, %range, limit => 50) } },
    \%expect, 'level facet: one bucket per canonical level';

{
    my $n = 0;
    $n += $_->{count} for grep { $_->{service} ne 'p110-pattern' }
        @{ $storage->get_patterns(level => 'WARN', %range, limit => 100) };
    is $n, $expect{WARN}, 'patterns level=WARN counts every stored spelling';

    my @p = grep { $_->{service} eq 'p110-pattern' } @{ $storage->get_patterns(%range, limit => 100) };
    is scalar(@p), 1, 'WARNING and WARN rows of one message are one pattern';
    is_deeply [ map { [ $_->{level}, $_->{count} ] } @p ], [ [ 'WARN', 2 ] ], 'grouped under the canonical level';
}

{
    my ($ast) = Purl::Util::KQL::parse_kql('service:t110-* AND level:crit*');
    is $storage->count(kql => $ast, %range), $expect{FATAL},
        'level:crit* finds the rows stored as FATAL (and old crit/CRITICAL rows)';
}

{
    my %sum;
    for my $b (@{ $storage->histogram(%all, interval => '1 day', %range) }) {
        $sum{$_} += $b->{$_} // 0 for qw(errors warnings info);
    }
    is $sum{warnings}, $expect{WARN}, 'histogram warnings: every WARN spelling';
    is $sum{errors}, $expect{ERROR} + $expect{FATAL}, 'histogram errors: ERR/crit/PANIC... included';
    is $sum{info}, $expect{INFO}, 'histogram info: NOTICE included';
}

done_testing;

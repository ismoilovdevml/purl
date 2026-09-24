#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::KQL qw(parse_kql);

# ============================================
# #105: log levels are case-insensitive.
#
# A production cluster listed `INFO 532K` and `info 1` as two facet values. Two halves:
#   1. every row written from now on carries ONE canonical spelling (upper case,
#      what the UI colour map and the level filters already use), and
#   2. rows already stored in another case are still found and counted together.
#      `level` is part of the sort key, so ClickHouse refuses to rewrite it
#      (ALTER UPDATE -> CANNOT_UPDATE_COLUMN); queries compare upper(level).
# ============================================

{
    package LevelCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    with 'Purl::Storage::ClickHouse::Ingest';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

subtest 'ingest stores one canonical (upper-case) level' => sub {
    my %cases = (
        'warn'     => 'WARN',
        'Info'     => 'INFO',
        ' error '  => 'ERROR',
        'WARNING'  => 'WARNING',
        ''         => 'INFO',
        "\t"       => 'INFO',
    );
    for my $in (sort keys %cases) {
        my $s = LevelCH->new;
        $s->insert({ level => $in, message => 'm' });
        is $s->_buffer->[0]{level}, $cases{$in}, "insert: '$in' -> '$cases{$in}'";
    }

    my $s = LevelCH->new;
    $s->insert({ message => 'no level at all' });
    is $s->_buffer->[0]{level}, 'INFO', 'missing level defaults to INFO';

    $s = LevelCH->new;
    $s->insert_batch([ { level => 'debug' }, { level => 'Fatal' } ]);
    is_deeply [ map { $_->{level} } @{ $s->_buffer } ], [ 'DEBUG', 'FATAL' ],
        'insert_batch (K8s audit, Storage API) normalises too';

    # The hashref is shared with the live-tail broadcast; it must see the same
    # value that was stored.
    my $log = { level => 'warn' };
    LevelCH->new->insert($log);
    is $log->{level}, 'WARN', 'caller\'s hash normalised in place (live tail agrees with storage)';
};

subtest 'KQL level filter matches every stored case' => sub {
    my ($ast) = parse_kql('level:warn');
    my ($sql, $bind) = LevelCH->new->_build_where_clause(kql => $ast);
    like $sql, qr/upper\(level\) = \{p_kql_0:String\}/, 'compares upper(level)';
    is $bind->{p_kql_0}, 'WARN', 'value upper-cased';

    ($ast) = parse_kql('level:WAR*');
    ($sql, $bind) = LevelCH->new->_build_where_clause(kql => $ast);
    like $sql, qr/upper\(level\) LIKE \{p_kql_0:String\}/, 'wildcard compares upper(level)';
    is $bind->{p_kql_0}, 'WAR%', 'pattern upper-cased';
};

subtest 'flat level param (dashboard widgets, histogram) matches every stored case' => sub {
    my ($sql, $bind) = LevelCH->new->_build_where_clause(level => 'warn');
    like $sql, qr/upper\(level\) = \{p_level:String\}/, 'single level';
    is $bind->{p_level}, 'WARN', 'bound upper-case';

    ($sql, $bind) = LevelCH->new->_build_where_clause(level => [ 'error', 'Warn' ]);
    like $sql, qr/upper\(level\) IN \(\{p_level_0:String\}, \{p_level_1:String\}\)/, 'level list';
    is_deeply [ @{$bind}{qw(p_level_0 p_level_1)} ], [ 'ERROR', 'WARN' ], 'list bound upper-case';
};

done_testing;

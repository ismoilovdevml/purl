#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::KQL qw(parse_kql);

# ============================================
# #110 — one name per level. Syslog sends WARNING, Vector/OTLP send WARN; both
# were stored as they came and showed up as two facet buckets needing two
# filters. The database-backed half is t/level_synonyms_clickhouse.t.
# ============================================

{
    package SynCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    with 'Purl::Storage::ClickHouse::Ingest';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

subtest 'ingest stores the canonical name' => sub {
    my $s = SynCH->new;
    $s->insert_batch([ map { { level => $_, message => 'm' } } qw(WARNING err crit Notice PANIC warn) ]);
    is_deeply [ map { $_->{level} } @{ $s->_buffer } ], [ qw(WARN ERROR FATAL INFO FATAL WARN) ],
        'synonyms folded at ingest';
};

subtest 'KQL level filter matches every synonym' => sub {
    my ($ast) = parse_kql('level:WARNING OR service:api');
    my ($sql, $bind) = SynCH->new->_build_where_clause(kql => $ast);
    like $sql, qr/\(level IN \((?:\{p_kql_\d:String\}(?:, )?){6}\)\)/, 'plain (prunable) IN over bound spellings';
    unlike $sql, qr/upper\(level\)/, 'never upper(level) for an exact level';
    is_deeply [ @{$bind}{map { "p_kql_$_" } 0 .. 5} ], [ qw(WARN warn Warn WARNING warning Warning) ],
        'every spelling bound';
    is $bind->{p_kql_6}, 'api', 'the next term gets the next parameter';

    ($ast) = parse_kql('level:"crit"');
    ($sql, $bind) = SynCH->new->_build_where_clause(kql => $ast);
    is scalar(keys %$bind), 21, 'a quoted synonym expands too (7 spellings x 3 cases)';
};

subtest 'KQL level wildcard also expands against the synonym table' => sub {
    my ($ast) = parse_kql('level:crit*');
    my ($sql, $bind) = SynCH->new->_build_where_clause(kql => $ast);
    like $sql, qr/\(upper\(level\) LIKE \{p_kql_0:String\} OR level IN \(/, 'LIKE, or the level CRIT* names';
    is $bind->{p_kql_0}, 'CRIT%', 'pattern upper-cased';
    ok +(grep { $_ eq 'FATAL' } values %$bind), 'crit* finds rows stored as FATAL';

    ($ast) = parse_kql('level:war*');
    (undef, $bind) = SynCH->new->_build_where_clause(kql => $ast);
    ok +(grep { $_ eq 'WARN' } values %$bind), 'war* covers WARN';

    ($ast) = parse_kql('level:zz*');
    ($sql) = SynCH->new->_build_where_clause(kql => $ast);
    is $sql, 'WHERE (upper(level) LIKE {p_kql_0:String})', 'no synonym matches: plain LIKE';

    ($ast) = parse_kql('level:a_b*');
    (undef, $bind) = SynCH->new->_build_where_clause(kql => $ast);
    is $bind->{p_kql_0}, 'A\\_B%', 'LIKE metacharacters still escaped';
};

subtest 'flat level filter validates synonyms as their canonical name' => sub {
    my $s = SynCH->new;
    is $s->_validate_level('Warning'), 'WARN', 'WARNING -> WARN';
    is $s->_validate_level('crit'), 'FATAL', 'CRIT -> FATAL';
    is $s->_validate_level('audit'), undef, 'unknown level still rejected';

    my ($sql, $bind) = $s->_build_where_clause(level => [ 'warning', 'WARN' ]);
    is scalar(grep { /^p_level_/ } keys %$bind), 6, 'duplicate levels bound once (6 spellings of WARN)';
};

subtest 'live tail level filter uses canonical names' => sub {
    require Purl::API::LiveTail;
    my @logs = map { { level => $_, message => 'm' } } qw(WARN ERROR INFO);
    my $got = sub { [ map { $_->{level} } Purl::API::LiveTail::filter_logs({ level => $_[0] }, \@logs) ] };
    is_deeply $got->('WARNING'), ['WARN'], 'WARNING subscriber gets WARN rows';
    is_deeply $got->([ 'err', 'notice' ]), [ 'ERROR', 'INFO' ], 'list of synonyms';
    is_deeply $got->('warn'), ['WARN'], 'plain case-insensitive match still works';
};

# The shared table itself.
require_ok 'Purl::Util::Level';
Purl::Util::Level->import(qw(canonical_level level_synonyms));

subtest 'canonical names' => sub {
    my %cases = (
        WARNING => 'WARN',  warning => 'WARN', WARN => 'WARN',
        ERR => 'ERROR',     err => 'ERROR',    ERROR => 'ERROR',
        CRIT => 'FATAL',    Critical => 'FATAL', EMERG => 'FATAL', EMERGENCY => 'FATAL',
        ALERT => 'FATAL',   PANIC => 'FATAL',  FATAL => 'FATAL',
        NOTICE => 'INFO',   ' info ' => 'INFO',
        DEBUG => 'DEBUG',   trace => 'TRACE',
        audit => 'AUDIT',   # unknown levels are kept, upper-cased
        ''    => '',
    );
    is canonical_level($_), $cases{$_}, "'$_' -> '$cases{$_}'" for sort keys %cases;
    is canonical_level(undef), '', 'undef -> empty';
};

subtest 'synonyms of a level' => sub {
    is_deeply [ level_synonyms('warn') ], [ 'WARN', 'WARNING' ], 'WARN';
    is_deeply [ level_synonyms('WARNING') ], [ 'WARN', 'WARNING' ], 'a synonym expands to the same set';
    is_deeply [ level_synonyms('fatal') ], [ qw(FATAL ALERT CRIT CRITICAL EMERG EMERGENCY PANIC) ], 'FATAL';
    is_deeply [ level_synonyms('debug') ], [ 'DEBUG' ], 'no synonyms';
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::KQL qw(parse_kql);

# ============================================
# Storage-side compiler: the Query + KQL roles composed exactly as
# Purl::Storage::ClickHouse composes them, minus the HTTP client.
# ============================================
{
    package MockCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

# Compile a query string straight through both halves of the pipeline.
sub compile {
    my ($query) = @_;
    my ($ast, $err) = parse_kql($query);
    return (undef, undef, $err) if $err;
    my ($sql, $bind) = MockCH->new->_build_where_clause(kql => $ast);
    return ($sql, $bind, undef);
}

# The bind values in the order the compiler emitted them.
sub bind_values {
    my ($bind) = @_;
    return [ map { $bind->{$_} } sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] } keys %$bind ];
}

# ============================================
# Tokenizer / grammar
# ============================================

subtest 'single field:value' => sub {
    my ($ast, $err) = parse_kql('level:error');
    is $err, undef, 'no error';
    is_deeply $ast, { op => 'term', field => 'level', value => 'error', quoted => 0 },
        'single term AST';
};

subtest 'bare term is free text' => sub {
    my ($ast, $err) = parse_kql('timeout');
    is $err, undef, 'no error';
    is_deeply $ast, { op => 'term', field => undef, value => 'timeout', quoted => 0 },
        'bare term has no field';
};

subtest 'empty query is not an error' => sub {
    for my $input (undef, '', '   ', "\t\n") {
        my ($ast, $err) = parse_kql($input);
        is $ast, undef, 'no AST';
        is $err, undef, 'no error either';
    }
};

subtest 'field names are case-insensitive, values are not' => sub {
    my ($ast) = parse_kql('SERVICE:Api');
    is $ast->{field}, 'service', 'field lower-cased';
    is $ast->{value}, 'Api',     'value untouched';
};

# ============================================
# BLOCKER regression: AND
# ============================================
#
# Live cluster before the fix (4 logs: 3 error / 1 info, svc-a and svc-b):
#   q=[level:error]                   total=1509
#   q=[service:svc-a]                 total=3
#   q=[service:svc-a AND level:error] total=0      <- should be 2
#   q=[level:error AND service:svc-a] total=2522   <- MORE than level:error
#
# Root cause: there was no parser. Controller::Logs matched ^([\w.]+):(.+)$ and
# handed the ENTIRE tail to one flat filter:
#   * "service:svc-a AND level:error" -> service = "svc-aANDlevelerror" (the
#     identifier sanitizer stripped spaces and the colon) -> zero rows;
#   * "level:error AND service:svc-a" -> level = "ERROR AND SERVICE:SVC-A",
#     which failed _validate_level, so the filter was DROPPED ENTIRELY and the
#     query degenerated to "no WHERE at all" -> every row in the table.
# An intersection is now compiled as an intersection, in either order.

subtest 'AND is an intersection and is order-independent' => sub {
    my ($sql_a, $bind_a, $err_a) = compile('service:svc-a AND level:error');
    my ($sql_b, $bind_b, $err_b) = compile('level:error AND service:svc-a');

    is $err_a, undef, 'no error (a)';
    is $err_b, undef, 'no error (b)';

    like $sql_a, qr/\bAND\b/, 'AND survives into the SQL';
    unlike $sql_a, qr/svc-a/, 'value never interpolated into the statement';
    unlike $sql_a, qr/position\(message[^)]*\)\s*>\s*0.*ERROR/s,
        'not degraded into a literal message search';

    is_deeply [ sort @{ bind_values($bind_a) } ],
              [ sort @{ bind_values($bind_b) } ],
              'both operand orders bind the same value set';

    is_deeply [ sort @{ bind_values($bind_a) } ], [ 'ERROR', 'svc-a' ],
        'service value keeps its dash; level is upper-cased';

    like $sql_a, qr/service\s*=\s*\{p_kql_\d+:String\}/, 'service compiled to equality';
    like $sql_a, qr/level\s*=\s*\{p_kql_\d+:String\}/,   'level compiled to equality';
};

subtest 'AND is never wider than either operand' => sub {
    my ($both)  = compile('service:svc-a AND level:error');
    my ($left)  = compile('service:svc-a');
    my ($right) = compile('level:error');

    # Structural proof of "intersection": the AND clause contains both operand
    # predicates joined by AND. The pre-fix bug produced a WHERE clause with
    # FEWER predicates than one operand alone.
    my $count_preds = sub { my $s = shift; my $n = () = $s =~ /\{p_kql_\d+:String\}/g; return $n };
    is $count_preds->($both), $count_preds->($left) + $count_preds->($right),
        'AND keeps every operand predicate';
    like $both, qr/\) AND \(/, 'operands joined with AND, each parenthesised';
};

subtest 'implicit AND (juxtaposition)' => sub {
    my ($ast, $err) = parse_kql('level:error service:api');
    is $err, undef, 'no error';
    is $ast->{op}, 'and', 'space between terms means AND';
    is scalar @{ $ast->{children} }, 2, 'two operands';
};

subtest 'AND chains of three' => sub {
    my ($sql, $bind) = compile('level:error AND service:api AND host:web1');
    is_deeply [ sort @{ bind_values($bind) } ], [ 'ERROR', 'api', 'web1' ],
        'all three operands bound';
    my $n = () = $sql =~ / AND /g;
    ok $n >= 2, 'at least two AND joins';
};

# ============================================
# OR
# ============================================

subtest 'OR is a union' => sub {
    my ($sql, $bind, $err) = compile('level:error OR level:warn');
    is $err, undef, 'no error';
    like $sql, qr/\) OR \(/, 'operands joined with OR';
    is_deeply [ sort @{ bind_values($bind) } ], [ 'ERROR', 'WARN' ], 'both levels bound';
};

subtest 'OR is order-independent' => sub {
    my (undef, $b1) = compile('level:error OR service:api');
    my (undef, $b2) = compile('service:api OR level:error');
    is_deeply [ sort @{ bind_values($b1) } ], [ sort @{ bind_values($b2) } ],
        'same value set either way';
};

subtest 'AND binds tighter than OR' => sub {
    # a AND b OR c  ==  (a AND b) OR c
    my ($ast) = parse_kql('level:error AND service:api OR service:web');
    is $ast->{op}, 'or', 'top node is OR';
    is $ast->{children}[0]{op}, 'and', 'left branch is the AND pair';
    is $ast->{children}[1]{field}, 'service', 'right branch is the lone term';

    my ($sql) = compile('level:error AND service:api OR service:web');
    like $sql, qr/\(\(.*\) AND \(.*\)\) OR \(/, 'grouping preserved in SQL';
};

# ============================================
# NOT
# ============================================

subtest 'NOT negates a single term' => sub {
    my ($sql, $bind, $err) = compile('NOT level:debug');
    is $err, undef, 'no error';
    like $sql, qr/NOT \(/, 'NOT emitted';
    is_deeply bind_values($bind), ['DEBUG'], 'value bound once';
};

subtest 'NOT binds tighter than AND' => sub {
    my ($ast) = parse_kql('service:api AND NOT level:debug');
    is $ast->{op}, 'and', 'top is AND';
    is $ast->{children}[1]{op}, 'not', 'right operand is the NOT';
    is $ast->{children}[1]{child}{field}, 'level', 'NOT wraps only the level term';
};

subtest 'NOT is case-insensitive and stacks' => sub {
    my ($ast) = parse_kql('not not level:error');
    is $ast->{op}, 'not', 'outer NOT';
    is $ast->{child}{op}, 'not', 'inner NOT';
    is $ast->{child}{child}{field}, 'level', 'term underneath';
};

subtest 'NOT over a group' => sub {
    my ($sql, $bind) = compile('NOT (level:error OR level:warn)');
    like $sql, qr/NOT \(\(.*\) OR \(.*\)\)/, 'negates the whole group, not just the first term';
    is_deeply [ sort @{ bind_values($bind) } ], [ 'ERROR', 'WARN' ], 'both bound';
};

# ============================================
# Parentheses
# ============================================

subtest 'parentheses override precedence' => sub {
    my ($ast) = parse_kql('(level:error OR level:warn) AND service:api');
    is $ast->{op}, 'and', 'top is AND';
    is $ast->{children}[0]{op}, 'or', 'left branch is the parenthesised OR';

    my ($sql) = compile('(level:error OR level:warn) AND service:api');
    like $sql, qr/\(\(.*OR.*\)\) AND \(/, 'OR group kept intact under the AND';
};

subtest 'nested parentheses' => sub {
    my ($sql, $bind, $err) = compile('((level:error))');
    is $err, undef, 'no error';
    is_deeply bind_values($bind), ['ERROR'], 'redundant parens collapse cleanly';
};

subtest 'unbalanced parentheses are rejected' => sub {
    for my $q ('(level:error', 'level:error)', '((level:error)') {
        my ($ast, $err) = parse_kql($q);
        is $ast, undef, "no AST for '$q'";
        like $err, qr/paren|incomplete/, "'$q' rejected";
    }
};

subtest 'nesting depth is bounded' => sub {
    my $deep = ('(' x 100) . 'level:error' . (')' x 100);
    my ($ast, $err) = parse_kql($deep);
    is $ast, undef, 'no AST';
    like $err, qr/deep/, 'depth limit reported';
};

# ============================================
# Quoted phrases
# ============================================

subtest 'quoted phrase keeps spaces' => sub {
    my ($ast, $err) = parse_kql('"connection refused"');
    is $err, undef, 'no error';
    is $ast->{value}, 'connection refused', 'phrase kept whole';
    is $ast->{quoted}, 1, 'marked quoted';
};

subtest 'quoted boolean keyword is a literal, not an operator' => sub {
    my ($ast) = parse_kql('"AND"');
    is $ast->{op}, 'term', 'quoted AND is a term';
    is $ast->{value}, 'AND', 'value preserved';

    my ($ast2) = parse_kql('message:"a AND b"');
    is $ast2->{op}, 'term', 'quoted phrase inside a field is one term';
    is $ast2->{value}, 'a AND b', 'operator text preserved verbatim';
};

subtest 'quoted field value with spaces' => sub {
    my ($sql, $bind, $err) = compile('service:"my service" AND level:error');
    is $err, undef, 'no error';
    is_deeply [ sort @{ bind_values($bind) } ], [ 'ERROR', 'my service' ],
        'phrase bound as one value';
};

subtest 'single quotes work too, and escapes survive' => sub {
    my ($ast) = parse_kql(q{message:'it\'s down'});
    is $ast->{value}, "it's down", 'escaped quote unescaped';
};

subtest 'unterminated quote is rejected' => sub {
    my ($ast, $err) = parse_kql('message:"never closed');
    is $ast, undef, 'no AST';
    like $err, qr/unterminated/, 'reported as unterminated';
};

# ============================================
# Invalid input
# ============================================

subtest 'incomplete expressions are rejected' => sub {
    for my $q ('level:error AND', 'AND level:error', 'OR', 'NOT', 'level:', 'level: ') {
        my ($ast, $err) = parse_kql($q);
        is $ast, undef, "no AST for '$q'";
        ok defined $err && length $err, "'$q' produced an error message";
    }
};

subtest 'token count is bounded' => sub {
    my $huge = join(' AND ', map { "level:error" } 1 .. 500);
    my ($ast, $err) = parse_kql($huge);
    is $ast, undef, 'no AST';
    like $err, qr/complex/, 'token limit reported';
};

# ============================================
# SQL safety
# ============================================

subtest 'injection attempts never reach the statement' => sub {
    my ($sql, $bind, $err) = compile(q{service:"x' OR 1=1 --"});
    is $err, undef, 'parses as a plain phrase';
    unlike $sql, qr/OR 1=1/, 'payload absent from the SQL text';
    is_deeply bind_values($bind), [q{x' OR 1=1 --}], 'payload confined to a bind parameter';
};

subtest 'every KQL value is a bind parameter' => sub {
    my ($sql, $bind) = compile('level:error AND service:api AND message:"boom" AND meta.pod:web-1');
    my @placeholders = $sql =~ /\{(p_kql_\d+):String\}/g;
    is scalar(@placeholders), scalar(keys %$bind), 'placeholder count matches bind count';
    is scalar(keys %{ { map { $_ => 1 } @placeholders } }), scalar(@placeholders),
        'placeholder names are unique';
};

# ============================================
# Field mapping
# ============================================

subtest 'message and raw are substring searches' => sub {
    my ($sql, $bind) = compile('message:boom');
    like $sql, qr/position\(message, \{p_kql_0:String\}\) > 0/, 'position() on message';
    is_deeply bind_values($bind), ['boom'], 'value bound';

    my ($sql2) = compile('raw:boom');
    like $sql2, qr/position\(raw,/, 'position() on raw';
};

subtest 'bare term searches the message column' => sub {
    my ($sql, $bind) = compile('timeout');
    like $sql, qr/position\(message,/, 'bare term hits message';
    is_deeply bind_values($bind), ['timeout'], 'value bound';
};

subtest 'meta.* matches field name and value in the meta JSON' => sub {
    my ($sql, $bind) = compile('meta.namespace:production');
    like $sql, qr/position\(meta, \{p_kql_0:String\}\).*position\(meta, \{p_kql_1:String\}\)/,
        'two position() checks against meta';
    is_deeply bind_values($bind), [ 'namespace', 'production' ], 'field then value';
};

subtest 'unknown field falls back to a message search' => sub {
    my ($sql, $bind) = compile('nosuchfield:boom');
    like $sql, qr/position\(message,/, 'falls back to message';
    is_deeply bind_values($bind), ['boom'], 'value used, field dropped';
};

subtest 'wildcards become LIKE with metacharacters escaped' => sub {
    my ($sql, $bind) = compile('service:api-*');
    like $sql, qr/service LIKE \{p_kql_0:String\}/, 'LIKE used';
    is_deeply bind_values($bind), ['api-%'], 'star became percent';

    # A literal underscore must not silently become a single-char wildcard.
    my (undef, $bind2) = compile('service:svc_a*');
    is_deeply bind_values($bind2), ['svc\\_a%'], 'underscore escaped, star translated';

    # Quoting disables wildcard interpretation.
    my ($sql3, $bind3) = compile('service:"api-*"');
    like $sql3, qr/service = /, 'quoted value is an exact match';
    is_deeply bind_values($bind3), ['api-*'], 'star kept literal';
};

# ============================================
# Composition with the flat filter params
# ============================================

subtest 'KQL is ANDed with flat filters, not merged into them' => sub {
    my ($ast) = parse_kql('level:error OR level:warn');
    my ($sql) = MockCH->new->_build_where_clause(service => 'api', kql => $ast);

    like $sql, qr/service = \{p_service:String\}/, 'flat service filter present';
    like $sql, qr/\(\(.*\) OR \(.*\)\)/, 'KQL OR stays inside its own parentheses';
    # The OR must not escape and turn the service filter into an alternative.
    unlike $sql, qr/service = \{p_service:String\} OR/, 'OR did not leak past the KQL fragment';
};

done_testing();

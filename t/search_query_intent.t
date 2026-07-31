#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::SearchQuery qw(plan_search_query looks_like_kql);

# ============================================
# REGRESSION (#36): plain-text log search must not 400.
#
# Routing EVERY search string through the KQL grammar broke the single most
# common thing the search box is used for — pasting a fragment of a log line:
#
#   "at Foo::bar()"      -> HTTP 400  unexpected 'rparen'
#   "timeout)"           -> HTTP 400  unbalanced parentheses
#   "connection refused" -> 200, but silently became an AND of two terms
#                           instead of a phrase match
#
# The rule pinned here: a string is parsed as KQL ONLY when it carries an
# unambiguous marker (bare UPPER-CASE AND/OR/NOT, known_field:value with no
# spaces around the colon, or a wholly quoted phrase). Everything else is a
# literal substring search, exactly as it was before KQL existed.
#
# The strict half still holds: a string that DID declare itself as KQL and
# then fails to parse is an error, never a silent fallback.
# ============================================

# Compile the resulting params the way the storage layer does, so the test
# proves the literal path really becomes a bound substring match and not
# interpolated SQL.
{
    package MockCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

sub where_for {
    my ($query) = @_;
    my ($params, $err) = plan_search_query($query);
    return (undef, undef, $err) if $err;
    my ($sql, $bind) = MockCH->new->_build_where_clause(%$params);
    return ($sql, $bind, undef);
}

# ============================================
# Real log text stays literal
# ============================================

subtest 'a pasted stack-trace fragment is literal text, not a syntax error' => sub {
    my $q = 'at Foo::bar()';

    ok !looks_like_kql($q), 'no KQL marker in a stack-trace fragment';

    my ($params, $err) = plan_search_query($q);
    is $err, undef, 'no error — this used to be a 400';
    is $params->{query}, 'at Foo::bar()', 'searched verbatim';
    ok !exists $params->{kql}, 'not routed through the grammar';
};

subtest 'an unbalanced paren in log text is literal text' => sub {
    my ($params, $err) = plan_search_query('timeout)');
    is $err, undef, 'no error — this used to be a 400';
    is $params->{query}, 'timeout)', 'the paren is part of the search text';
};

subtest 'a two-word phrase stays a phrase, not an AND of two terms' => sub {
    my ($params, $err) = plan_search_query('connection refused');
    is $err, undef, 'no error';
    is $params->{query}, 'connection refused',
        'both words matched together — an AND would also match a line with '
        . '"connection" and "refused" far apart';
    ok !exists $params->{kql}, 'no boolean AST built';
};

subtest 'lower-case and/or/not in prose are words, not operators' => sub {
    for my $q ('connection reset and retried', 'accepted or rejected', 'not found') {
        my ($params, $err) = plan_search_query($q);
        is $err, undef, "'$q' parses";
        is $params->{query}, $q, "'$q' searched verbatim";
    }
};

subtest 'log text that merely contains a colon stays literal' => sub {
    for my $q ('ERROR: disk full', 'host: unreachable', '"level":"error"',
               'GET /v1/users: 500', 'C:\\Users\\svc\\app.log') {
        my ($params, $err) = plan_search_query($q);
        is $err, undef, "'$q' parses";
        is $params->{query}, $q, "'$q' searched verbatim";
    }
};

subtest 'literal search is a bound parameter, never interpolated SQL' => sub {
    my ($sql, $bind) = where_for(q{Robert'); DROP TABLE logs;--});
    like $sql, qr/position\(message, \{p_query:String\}\) > 0/,
        'compiled to a bound substring match';
    is $bind->{p_query}, q{Robert'); DROP TABLE logs;--},
        'the whole string travels as a bind value';
    unlike $sql, qr/DROP TABLE/, 'nothing from the user reached the statement text';
};

subtest 'surrounding whitespace is trimmed off a literal search' => sub {
    my ($params) = plan_search_query("  disk full \n");
    is $params->{query}, 'disk full', 'leading/trailing whitespace dropped';
};

subtest 'an empty query filters on nothing' => sub {
    for my $q (undef, '', '   ') {
        my ($params, $err) = plan_search_query($q);
        is $err, undef, 'not an error';
        is_deeply $params, {}, 'no filter params at all';
    }
};

# ============================================
# Explicit KQL is still parsed strictly
# ============================================

subtest 'known_field:value is KQL' => sub {
    my ($params, $err) = plan_search_query('level:error');
    is $err, undef, 'no error';
    is_deeply $params->{kql},
        { op => 'term', field => 'level', value => 'error', quoted => 0 },
        'parsed as a field term';
    ok !exists $params->{query}, 'not also searched literally';
};

subtest 'meta.<field>:value is KQL' => sub {
    my ($params) = plan_search_query('meta.namespace:production');
    is $params->{kql}{field}, 'meta.namespace', 'meta sub-field recognised';
};

subtest 'a bare upper-case boolean is KQL' => sub {
    my ($params, $err) = plan_search_query('timeout AND retry');
    is $err, undef, 'no error';
    is $params->{kql}{op}, 'and', 'AND built a boolean node';
    is scalar @{ $params->{kql}{children} }, 2, 'two operands';
};

subtest 'NOT and OR are markers too' => sub {
    is +(plan_search_query('NOT level:info'))[0]{kql}{op}, 'not', 'NOT recognised';
    is +(plan_search_query('a OR b'))[0]{kql}{op}, 'or', 'OR recognised';
};

subtest 'a wholly quoted string is an explicit phrase' => sub {
    my ($params, $err) = plan_search_query('"connection refused"');
    is $err, undef, 'no error';
    is_deeply $params->{kql},
        { op => 'term', field => undef, value => 'connection refused', quoted => 1 },
        'quotes requested a phrase and were not searched for themselves';
};

subtest 'broken KQL is still an error, never a silent literal fallback' => sub {
    # This is the defect the parser was written to fix: dropping an
    # unparsable filter made `level:error AND service:x` return MORE rows
    # than `level:error` alone. Falling back to a literal here would bring
    # that back, so an explicit-but-broken expression must fail loudly.
    for my $q ('level:error AND', 'level:error AND (service:api',
               'service:api OR)') {
        my ($params, $err) = plan_search_query($q);
        ok defined $err, "'$q' reports a syntax error";
        is $params, undef, "'$q' produced no filter params at all";
    }
};

subtest 'field name boundaries are respected' => sub {
    # `myhost:x` is not the `host` field, and `Foo::bar` is not a field at all.
    ok !looks_like_kql('myhost:down'), 'a longer word ending in a field name is not a field';
    ok !looks_like_kql('at Foo::bar()'), 'a double colon is never a field separator';
    ok  looks_like_kql('host:web-01'), 'the real field name is';
    ok  looks_like_kql('(host:web-01)'), 'and it is recognised after an opening paren';
};

subtest 'RANDOM is not the AND operator' => sub {
    ok !looks_like_kql('RANDOM failure'), 'AND inside a word is not an operator';
    ok !looks_like_kql('BAND practice'),  'nor is a word ending in AND';
    ok  looks_like_kql('a AND b'),        'a standalone AND is';
};

# ============================================
# REGRESSION (#44): a bare upper-case operator is only an operator in
# OPERATOR POSITION.
#
# `404 NOT FOUND` used to be read as `404 AND NOT FOUND`, which cannot match
# anything: every line carrying the phrase also carries FOUND. No error, no
# 400 — a silently wrong answer for one of the most common log searches there
# is. Same for `301 NOT MODIFIED` and `user NOT authorized`.
# ============================================

subtest 'HTTP status phrases containing NOT stay literal' => sub {
    for my $q ('404 NOT FOUND', '301 NOT MODIFIED', 'user NOT authorized',
               'Value must NOT be null') {
        ok !looks_like_kql($q), "'$q' carries no operator-position marker";

        my ($params, $err) = plan_search_query($q);
        is $err, undef, "'$q' is not an error";
        is $params->{query}, $q, "'$q' searched as the phrase the user typed";
        ok !exists $params->{kql}, "'$q' built no NOT node";
    }
};

subtest '404 NOT FOUND compiles to one bound substring match' => sub {
    # The proof that matters: ONE position() over the whole phrase. The old
    # reading produced `position(...404...) AND NOT position(...FOUND...)`,
    # which is guaranteed to return zero rows for this input.
    my ($sql, $bind, $err) = where_for('404 NOT FOUND');
    is $err, undef, 'no syntax error';
    like $sql, qr/position\(message, \{p_query:String\}\) > 0/,
        'a single bound substring match';
    unlike $sql, qr/\bNOT\b/, 'no NOT was emitted into the SQL';
    is $bind->{p_query}, '404 NOT FOUND', 'the whole phrase is the bind value';
};

subtest 'NOT in real operator position is still a marker' => sub {
    ok looks_like_kql('NOT level:info'),  'at the start of the string';
    ok looks_like_kql('(NOT level:info)'), 'after an opening paren';
    ok looks_like_kql('level:error AND NOT service:api'), 'after AND';
    ok looks_like_kql('level:error OR NOT service:api'),  'after OR';

    my ($params) = plan_search_query('NOT timeout');
    is $params->{kql}{op}, 'not', 'a leading NOT still negates';
};

subtest 'AND/OR are markers only between two operands' => sub {
    # MINOR from the same review: an operator with nothing to join is text.
    for my $q ('OR', 'AND', 'NOT', 'failed (OR timeout)', 'retry AND') {
        ok !looks_like_kql($q), "'$q' has no operator to apply";
        my ($params, $err) = plan_search_query($q);
        is $err, undef, "'$q' is not a 400";
        is $params->{query}, $q, "'$q' searched verbatim";
    }
};

subtest 'the surviving heuristic is not disturbed by the position rule' => sub {
    # Cases the review attacked and found correct — pinned so a later tweak to
    # the marker rule cannot quietly re-break them.
    for my $q ('{"level":"error"}', 'http://host:8080/path',
               'C:\\Users\\app\\log.txt', '2001:db8::1', 'NOT_FOUND',
               'ENOTFOUND', 'Caused by: java.lang.RuntimeException') {
        ok !looks_like_kql($q), "'$q' stays literal";
    }
};

done_testing();

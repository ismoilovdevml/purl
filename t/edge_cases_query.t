#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Query is a Moo::Role, so we need a consumer class
{
    package TestQueryEdge;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';

    sub _convert_to_clickhouse_ts {
        my ($self, $ts) = @_;
        return $ts if $ts =~ /^\d{4}-\d{2}-\d{2}/;
        return $ts;
    }
}

my $q = TestQueryEdge->new;

# ============================================
# Unicode characters in queries
# ============================================
subtest 'unicode in search queries' => sub {
    # Emoji in query
    my ($sql, $params) = $q->_build_where_clause(query => "server crashed \x{1F4A5}");
    like $sql, qr/position\(message/, 'emoji query generates position() clause';
    is $params->{p_query}, "server crashed \x{1F4A5}", 'emoji preserved in param';

    # CJK characters
    ($sql, $params) = $q->_build_where_clause(query => "\x{4F60}\x{597D}\x{4E16}\x{754C}");
    like $sql, qr/position\(message/, 'CJK query generates position() clause';
    is $params->{p_query}, "\x{4F60}\x{597D}\x{4E16}\x{754C}", 'CJK preserved in param';

    # Arabic characters
    ($sql, $params) = $q->_build_where_clause(query => "\x{0645}\x{0631}\x{062D}\x{0628}\x{0627}");
    like $sql, qr/position\(message/, 'Arabic query generates position() clause';
    is $params->{p_query}, "\x{0645}\x{0631}\x{062D}\x{0628}\x{0627}", 'Arabic preserved in param';
};

subtest 'unicode in _quote_string' => sub {
    my $result = $q->_quote_string("\x{1F600} emoji test");
    like $result, qr/emoji test/, 'emoji in quoted string';
    is $result, "'\x{1F600} emoji test'", 'emoji properly quoted';

    $result = $q->_quote_string("\x{4E2D}\x{6587}");
    is $result, "'\x{4E2D}\x{6587}'", 'CJK properly quoted';
};

# ============================================
# Very long queries (>10KB)
# ============================================
subtest 'very long query string' => sub {
    my $long_query = 'a' x 10240;  # 10KB
    my ($sql, $params) = $q->_build_where_clause(query => $long_query);
    like $sql, qr/position\(message/, 'long query generates clause';
    is length($params->{p_query}), 10240, 'long query preserved fully';
};

subtest 'very long service name sanitization' => sub {
    my $long_svc = 'a' x 1000;
    my $result = $q->_sanitize_identifier($long_svc);
    ok defined $result, 'very long identifier accepted (sanitize does not truncate)';
};

# ============================================
# Special characters
# ============================================
subtest 'special characters in _quote_string' => sub {
    # Wildcard asterisk
    is $q->_quote_string('test*'), "'test*'", 'asterisk preserved in quote';

    # Double quotes
    is $q->_quote_string('say "hello"'), "'say \"hello\"'", 'double quotes preserved';

    # Backslash
    is $q->_quote_string('path\\to\\file'), "'path\\\\to\\\\file'", 'backslash escaped';

    # Null byte
    my $with_null = "before\x00after";
    my $quoted = $q->_quote_string($with_null);
    ok defined $quoted, 'null byte in string does not crash';

    # Tab and newline
    is $q->_quote_string("line1\nline2"), "'line1\nline2'", 'newline preserved in quote';
    is $q->_quote_string("col1\tcol2"), "'col1\tcol2'", 'tab preserved in quote';
};

subtest 'special characters in sanitize_identifier' => sub {
    is $q->_sanitize_identifier('svc;DROP TABLE--'), 'svcDROPTABLE--', 'SQL injection chars stripped, dashes kept';
    is $q->_sanitize_identifier("null\x00byte"), 'nullbyte', 'null byte stripped';
    is $q->_sanitize_identifier('service name'), 'servicename', 'space stripped';
    is $q->_sanitize_identifier("tab\there"), 'tabhere', 'tab stripped';
    is $q->_sanitize_identifier("new\nline"), 'newline', 'newline stripped';
};

# ============================================
# Nested meta field access
# ============================================
subtest 'nested meta field access' => sub {
    # meta.deeply is a valid single-level meta field
    is $q->_validate_field('meta.deeply'), 'meta.deeply', 'single-level custom meta accepted';

    # meta.deeply.nested has two dots - not matching ^meta\.(\w+)$
    is $q->_validate_field('meta.deeply.nested'), undef, 'double-nested meta field rejected';

    # meta.a.b.c - triple nested
    is $q->_validate_field('meta.a.b.c'), undef, 'triple-nested meta field rejected';

    # meta with special chars in subfield
    is $q->_validate_field('meta.bad;field'), undef, 'meta field with semicolon rejected';
    is $q->_validate_field('meta.bad field'), undef, 'meta field with space rejected';
};

# ============================================
# Empty string queries
# ============================================
subtest 'empty string query' => sub {
    my ($sql, $params) = $q->_build_where_clause(query => '');
    is $sql, '', 'empty query produces no WHERE clause';
    is_deeply $params, {}, 'no params for empty query';
};

subtest 'empty string in various validators' => sub {
    is $q->_validate_field(''), undef, 'empty field rejected';
    is $q->_validate_level(''), undef, 'empty level rejected';
    is $q->_sanitize_identifier(''), undef, 'empty identifier rejected';
    is $q->_validate_uuid(''), 0, 'empty UUID rejected';
    is $q->_sanitize_trace_id(''), undef, 'empty trace_id rejected';
};

# ============================================
# Whitespace-only queries
# ============================================
subtest 'whitespace-only query' => sub {
    my ($sql, $params) = $q->_build_where_clause(query => '   ');
    # Whitespace query is truthy, so it should produce a clause
    like $sql, qr/position\(message/, 'whitespace query generates clause';
    is $params->{p_query}, '   ', 'whitespace preserved in param';
};

subtest 'whitespace in validators' => sub {
    is $q->_sanitize_identifier('   '), undef, 'whitespace-only identifier rejected';
    is $q->_validate_field('   '), undef, 'whitespace-only field rejected';
    is $q->_validate_level('   '), undef, 'whitespace-only level rejected';
};

# ============================================
# SQL injection attempts in field values
# ============================================
subtest 'SQL injection in _quote_string' => sub {
    my $injection1 = "'; DROP TABLE logs; --";
    like $q->_quote_string($injection1), qr/\\'/, 'single quote escaped in injection';

    my $injection2 = "1 OR 1=1";
    is $q->_quote_string($injection2), "'1 OR 1=1'", 'boolean injection safely quoted';

    my $injection3 = "UNION SELECT * FROM users";
    is $q->_quote_string($injection3), "'UNION SELECT * FROM users'", 'UNION injection safely quoted';
};

subtest 'SQL injection in service/host fields' => sub {
    # Service with SQL injection
    my ($sql, $params) = $q->_build_where_clause(service => "api'; DROP TABLE logs--");
    # sanitize_identifier strips non-allowed chars
    if ($sql) {
        unlike $sql, qr/DROP TABLE/, 'SQL injection stripped from service';
    } else {
        pass 'injection service produced no WHERE (fully sanitized away)';
    }
};

subtest 'SQL injection in level field' => sub {
    my ($sql, $params) = $q->_build_where_clause(level => "ERROR'; DROP TABLE logs--");
    is $sql, '', 'SQL injection in level produces no WHERE (invalid level)';
};

subtest 'SQL injection in trace_id' => sub {
    my $result = $q->_sanitize_trace_id("abcdef12'; DROP TABLE--");
    # Only hex chars and dashes survive
    ok !defined($result) || $result !~ /DROP/, 'SQL injection stripped from trace_id';
};

# ============================================
# Multiple consecutive operators (KQL edge cases)
# ============================================
subtest 'multiple consecutive operators in query' => sub {
    # These are free-text queries that go through position() - not parsed as KQL
    my ($sql, $params) = $q->_build_where_clause(query => 'AND AND');
    like $sql, qr/position\(message/, 'AND AND treated as text query';
    is $params->{p_query}, 'AND AND', 'AND AND preserved as-is';

    ($sql, $params) = $q->_build_where_clause(query => 'OR OR OR');
    like $sql, qr/position\(message/, 'OR OR OR treated as text query';
    is $params->{p_query}, 'OR OR OR', 'OR OR OR preserved as-is';
};

# ============================================
# Boundary conditions for _validate_int
# ============================================
subtest 'validate_int edge cases' => sub {
    is $q->_validate_int('0', 0, 0), 0, 'zero bounds with zero value';
    is $q->_validate_int('999999999', 0, 10000), 10000, 'very large int clamped to max';
    is $q->_validate_int('1' x 100), ('1' x 100) + 0, 'extremely large number accepted';
    is $q->_validate_int('0' x 50), 0, 'many zeros is still zero';
    is $q->_validate_int('007'), 7, 'leading zeros parsed as integer';
};

# ============================================
# UUID validation edge cases
# ============================================
subtest 'UUID edge cases' => sub {
    ok $q->_validate_uuid('00000000-0000-0000-0000-000000000000'), 'all-zero UUID valid';
    ok $q->_validate_uuid('ffffffff-ffff-ffff-ffff-ffffffffffff'), 'all-f UUID valid';
    ok !$q->_validate_uuid('550e8400-e29b-41d4-a716-446655440000 '), 'trailing space rejected';
    ok !$q->_validate_uuid(' 550e8400-e29b-41d4-a716-446655440000'), 'leading space rejected';
    # Note: Perl's $ matches before \n by default, so trailing newline passes regex
    # This documents the current behavior (not a security concern for parameterized queries)
    ok $q->_validate_uuid("550e8400-e29b-41d4-a716-446655440000\n"), 'trailing newline passes (Perl $ matches before \\n)';
};

# ============================================
# Combined filters with edge values
# ============================================
subtest 'combined filters with empty and valid values' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        level   => '',
        service => 'api',
        query   => '',
        host    => '',
    );
    # Only service should produce a WHERE clause
    like $sql, qr/service/, 'service filter present';
    unlike $sql, qr/level/, 'empty level not in WHERE';
    unlike $sql, qr/position\(message/, 'empty query not in WHERE';
};

subtest 'build_where_clause with undef values' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        level   => undef,
        service => undef,
        query   => undef,
    );
    is $sql, '', 'all undef produces no WHERE';
    is_deeply $params, {}, 'no params';
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Query is a Moo::Role, so we need a consumer class
{
    package TestQueryConsumer;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';

    # Stub for _convert_to_clickhouse_ts used in _build_where_clause
    sub _convert_to_clickhouse_ts {
        my ($self, $ts) = @_;
        return $ts if $ts =~ /^\d{4}-\d{2}-\d{2}/;
        return $ts;
    }
}

my $q = TestQueryConsumer->new;

# ============================================
# _quote_string — SQL string escaping
# ============================================
subtest '_quote_string basics' => sub {
    is $q->_quote_string('hello'), "'hello'", 'simple string';
    is $q->_quote_string(''), "''", 'empty string';
    is $q->_quote_string(undef), "''", 'undef returns empty quoted';
};

subtest '_quote_string escaping' => sub {
    is $q->_quote_string("it's"), "'it\\'s'", 'single quote escaped';
    is $q->_quote_string("back\\slash"), "'back\\\\slash'", 'backslash escaped';
    is $q->_quote_string("a'b\\c"), "'a\\'b\\\\c'", 'mixed escaping';
    is $q->_quote_string("'; DROP TABLE --"), "'\\'; DROP TABLE --'", 'SQL injection attempt escaped';
};

# ============================================
# _validate_field — whitelist field validation
# ============================================
subtest '_validate_field allowed fields' => sub {
    for my $f (qw(level service host timestamp message raw meta trace_id request_id span_id parent_span_id)) {
        ok defined $q->_validate_field($f), "field '$f' is allowed";
    }
};

subtest '_validate_field case insensitive' => sub {
    is $q->_validate_field('LEVEL'), 'level', 'uppercase normalized to lowercase';
    is $q->_validate_field('Service'), 'service', 'mixed case normalized';
};

subtest '_validate_field rejects invalid' => sub {
    is $q->_validate_field('nonexistent'), undef, 'unknown field rejected';
    is $q->_validate_field('DROP'), undef, 'SQL keyword rejected';
    is $q->_validate_field(undef), undef, 'undef rejected';
    is $q->_validate_field(''), undef, 'empty string rejected';
};

subtest '_validate_field meta sub-fields' => sub {
    is $q->_validate_field('meta.namespace'), 'meta.namespace', 'K8s namespace allowed';
    is $q->_validate_field('meta.pod'), 'meta.pod', 'K8s pod allowed';
    is $q->_validate_field('meta.container'), 'meta.container', 'K8s container allowed';
    is $q->_validate_field('meta.node'), 'meta.node', 'K8s node allowed';
    is $q->_validate_field('meta.cluster'), 'meta.cluster', 'K8s cluster allowed';
    is $q->_validate_field('meta.source'), 'meta.source', 'source allowed';
    is $q->_validate_field('meta.customfield'), 'meta.customfield', 'custom alphanumeric meta field allowed';
    is $q->_validate_field('meta.my_app'), 'meta.my_app', 'underscore meta field allowed';
    is $q->_validate_field('meta.1starts_with_num'), undef, 'meta field starting with number rejected';
    is $q->_validate_field('meta.'), undef, 'empty meta sub-field rejected';
};

# ============================================
# _validate_level — level whitelist
# ============================================
subtest '_validate_level allowed' => sub {
    for my $l (qw(TRACE DEBUG INFO NOTICE WARNING WARN ERROR CRITICAL ALERT EMERGENCY FATAL)) {
        is $q->_validate_level($l), $l, "level '$l' accepted";
    }
};

subtest '_validate_level case insensitive' => sub {
    is $q->_validate_level('error'), 'ERROR', 'lowercase normalized';
    is $q->_validate_level('Warning'), 'WARNING', 'mixed case normalized';
};

subtest '_validate_level rejects invalid' => sub {
    is $q->_validate_level('UNKNOWN'), undef, 'unknown level rejected';
    is $q->_validate_level(undef), undef, 'undef rejected';
    is $q->_validate_level(''), undef, 'empty string rejected';
};

# ============================================
# _sanitize_identifier — service/host names
# ============================================
subtest '_sanitize_identifier basics' => sub {
    is $q->_sanitize_identifier('my-service'), 'my-service', 'dash allowed';
    is $q->_sanitize_identifier('host_01'), 'host_01', 'underscore allowed';
    is $q->_sanitize_identifier('app.web.prod'), 'app.web.prod', 'dots allowed';
    is $q->_sanitize_identifier('svc*'), 'svc*', 'wildcard preserved for LIKE';
    is $q->_sanitize_identifier('*api*'), '*api*', 'multiple wildcards preserved';
};

subtest '_sanitize_identifier strips bad chars' => sub {
    is $q->_sanitize_identifier("my service"), 'myservice', 'spaces stripped';
    is $q->_sanitize_identifier("svc;DROP"), 'svcDROP', 'semicolon stripped';
    is $q->_sanitize_identifier("a'b"), 'ab', 'quote stripped';
    is $q->_sanitize_identifier(undef), undef, 'undef returns undef';
    is $q->_sanitize_identifier(''), undef, 'empty string returns undef';
    is $q->_sanitize_identifier('!@#$%'), undef, 'all-special-chars returns undef';
};

# ============================================
# _validate_int — integer validation with bounds
# ============================================
subtest '_validate_int basics' => sub {
    is $q->_validate_int('42'), 42, 'valid integer';
    is $q->_validate_int('0'), 0, 'zero is valid';
    is $q->_validate_int('999999'), 999999, 'large number';
    is $q->_validate_int(undef), undef, 'undef rejected';
    is $q->_validate_int('abc'), undef, 'non-numeric rejected';
    is $q->_validate_int('-5'), undef, 'negative rejected (no leading dash in pattern)';
    is $q->_validate_int('3.14'), undef, 'float rejected';
};

subtest '_validate_int with bounds' => sub {
    is $q->_validate_int('50', 1, 100), 50, 'within bounds';
    is $q->_validate_int('0', 1, 100), 1, 'clamped to min';
    is $q->_validate_int('200', 1, 100), 100, 'clamped to max';
    is $q->_validate_int('5', 5, 5), 5, 'exact bounds';
};

# ============================================
# _validate_order — sort direction
# ============================================
subtest '_validate_order' => sub {
    is $q->_validate_order('ASC'), 'ASC', 'ASC accepted';
    is $q->_validate_order('DESC'), 'DESC', 'DESC accepted';
    is $q->_validate_order('asc'), 'ASC', 'lowercase normalized';
    is $q->_validate_order('desc'), 'DESC', 'lowercase normalized';
    is $q->_validate_order(undef), 'DESC', 'undef defaults to DESC';
    is $q->_validate_order('RANDOM'), 'DESC', 'invalid defaults to DESC';
    is $q->_validate_order(''), 'DESC', 'empty defaults to DESC';
};

# ============================================
# _validate_uuid — UUID format
# ============================================
subtest '_validate_uuid valid' => sub {
    ok $q->_validate_uuid('550e8400-e29b-41d4-a716-446655440000'), 'valid UUID v4';
    ok $q->_validate_uuid('AABBCCDD-1234-5678-9012-AABBCCDDEEFF'), 'uppercase UUID';
};

subtest '_validate_uuid invalid' => sub {
    ok !$q->_validate_uuid(undef), 'undef rejected';
    ok !$q->_validate_uuid(''), 'empty rejected';
    ok !$q->_validate_uuid('not-a-uuid'), 'random string rejected';
    ok !$q->_validate_uuid('550e8400e29b41d4a716446655440000'), 'no dashes rejected';
    ok !$q->_validate_uuid('550e8400-e29b-41d4-a716-44665544000'), 'too short rejected';
    ok !$q->_validate_uuid('550e8400-e29b-41d4-a716-4466554400000'), 'too long rejected';
    ok !$q->_validate_uuid('ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ'), 'non-hex chars rejected';
};

# ============================================
# _sanitize_trace_id — trace/request/span IDs
# ============================================
subtest '_sanitize_trace_id valid' => sub {
    is $q->_sanitize_trace_id('abcdef12-3456-7890-abcd-ef1234567890'), 'abcdef12-3456-7890-abcd-ef1234567890', 'UUID-style trace ID';
    is $q->_sanitize_trace_id('ABCDEF1234567890'), 'abcdef1234567890', 'W3C-style hex, lowercased';
    is $q->_sanitize_trace_id('aabbccdd'), 'aabbccdd', '8-char minimum';
};

subtest '_sanitize_trace_id invalid' => sub {
    is $q->_sanitize_trace_id(undef), undef, 'undef rejected';
    is $q->_sanitize_trace_id('short'), undef, 'too short (< 8 chars after stripping)';
    is $q->_sanitize_trace_id(''), undef, 'empty rejected';
    my $long = 'a' x 37;
    is $q->_sanitize_trace_id($long), undef, 'too long (> 36 chars) rejected';
};

subtest '_sanitize_trace_id strips invalid chars' => sub {
    is $q->_sanitize_trace_id('abc!@#def12345678'), 'abcdef12345678', 'special chars stripped';
};

# ============================================
# _build_where_clause — full query building
# ============================================
subtest '_build_where_clause empty' => sub {
    my ($sql, $params) = $q->_build_where_clause();
    is $sql, '', 'no params = no WHERE';
    is_deeply $params, {}, 'empty params hash';
};

subtest '_build_where_clause single level' => sub {
    my ($sql, $params) = $q->_build_where_clause(level => 'ERROR');
    like $sql, qr/WHERE.*level = \{p_level:String\}/, 'level filter in WHERE';
    is $params->{p_level}, 'ERROR', 'level param bound';
};

subtest '_build_where_clause level array' => sub {
    my ($sql, $params) = $q->_build_where_clause(level => ['ERROR', 'WARNING']);
    like $sql, qr/level IN/, 'level IN clause';
    is $params->{p_level_0}, 'ERROR', 'first level bound';
    is $params->{p_level_1}, 'WARNING', 'second level bound';
};

subtest '_build_where_clause service wildcard' => sub {
    my ($sql, $params) = $q->_build_where_clause(service => 'api*');
    like $sql, qr/service LIKE/, 'wildcard generates LIKE';
    is $params->{p_service_pattern}, 'api%', 'wildcard converted to %';
};

subtest '_build_where_clause service exact' => sub {
    my ($sql, $params) = $q->_build_where_clause(service => 'web-app');
    like $sql, qr/service = \{p_service:String\}/, 'exact match';
    is $params->{p_service}, 'web-app', 'service param bound';
};

subtest '_build_where_clause full text search' => sub {
    my ($sql, $params) = $q->_build_where_clause(query => 'connection timeout');
    like $sql, qr/position\(message/, 'full-text uses position()';
    is $params->{p_query}, 'connection timeout', 'query param bound';
};

subtest '_build_where_clause time range' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        from => '2025-01-01 00:00:00.000',
        to   => '2025-01-02 00:00:00.000',
    );
    like $sql, qr/timestamp >= \{p_from:DateTime64/, 'from timestamp';
    like $sql, qr/timestamp <= \{p_to:DateTime64/, 'to timestamp';
    is $params->{p_from}, '2025-01-01 00:00:00.000', 'from param';
    is $params->{p_to}, '2025-01-02 00:00:00.000', 'to param';
};

subtest '_build_where_clause trace IDs' => sub {
    my $trace = 'abcdef1234567890';
    my ($sql, $params) = $q->_build_where_clause(trace_id => $trace);
    like $sql, qr/trace_id = \{p_trace_id:String\}/, 'trace_id filter';
    is $params->{p_trace_id}, $trace, 'trace_id bound';
};

subtest '_build_where_clause host filter' => sub {
    my ($sql, $params) = $q->_build_where_clause(host => 'prod-01');
    like $sql, qr/host = \{p_host:String\}/, 'host filter';
    is $params->{p_host}, 'prod-01', 'host bound';
};

subtest '_build_where_clause meta filter' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        meta_field => 'namespace',
        meta_value => 'production',
    );
    like $sql, qr/position\(meta/, 'meta uses position()';
    is $params->{p_meta_field}, 'namespace', 'meta field bound';
    is $params->{p_meta_value}, 'production', 'meta value bound';
};

subtest '_build_where_clause meta wildcard' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        meta_field => 'namespace',
        meta_value => 'prod*',
    );
    is $params->{p_meta_value}, 'prod', 'wildcard stripped from meta value';
};

subtest '_build_where_clause combined filters' => sub {
    my ($sql, $params) = $q->_build_where_clause(
        level   => 'ERROR',
        service => 'api',
        host    => 'prod-01',
        query   => 'timeout',
    );
    my @ands = ($sql =~ /AND/g);
    is scalar @ands, 3, 'multiple filters joined with AND';
    ok exists $params->{p_level}, 'level param present';
    ok exists $params->{p_service}, 'service param present';
    ok exists $params->{p_host}, 'host param present';
    ok exists $params->{p_query}, 'query param present';
};

subtest '_build_where_clause invalid level ignored' => sub {
    my ($sql, $params) = $q->_build_where_clause(level => 'INVALID');
    is $sql, '', 'invalid level produces no WHERE';
};

subtest '_build_where_clause invalid service ignored' => sub {
    my ($sql, $params) = $q->_build_where_clause(service => '!@#$');
    is $sql, '', 'all-special service produces no WHERE';
};

done_testing;

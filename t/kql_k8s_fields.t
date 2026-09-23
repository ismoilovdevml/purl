#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::KQL qw(parse_kql %FIELD_KIND);
use Purl::Util::SearchQuery qw(looks_like_kql plan_search_query);
use Purl::AI::SearchBarQuery qw(search_bar_query);
use Purl::API::Controller::Stats;

# ============================================
# #104: namespace / pod / container are first-class search fields.
#
# The chart's Vector DaemonSet puts them in `meta`; the logs table exposes them
# as materialized columns of the same name, so the language compiles them like
# host — equality, LIKE for an unquoted `*`, composable with NOT/AND/OR.
# ============================================

{
    package MockCH;
    use Moo;
    with 'Purl::Storage::ClickHouse::Query';
    with 'Purl::Storage::ClickHouse::KQL';
    sub _convert_to_clickhouse_ts { return $_[1] }
}

sub compile {
    my ($query) = @_;
    my ($ast, $err) = parse_kql($query);
    return (undef, undef, $err) if $err;
    my ($sql, $bind) = MockCH->new->_build_where_clause(kql => $ast);
    return ($sql, $bind, undef);
}

sub bind_values {
    my ($bind) = @_;
    return [ map { $bind->{$_} } sort { ($a =~ /(\d+)/)[0] <=> ($b =~ /(\d+)/)[0] } keys %$bind ];
}

subtest 'k8s fields are registered in the single field registry' => sub {
    is $FIELD_KIND{$_}, 'exact', "$_ is an exact-match field" for qw(namespace pod container);
};

subtest 'namespace:trk compiles to column equality, value bound' => sub {
    my ($sql, $bind, $err) = compile('namespace:trk');
    is $err, undef, 'parses';
    like $sql, qr/\(namespace = \{p_kql_0:String\}\)/, 'equality on the namespace column';
    unlike $sql, qr/position\(message/, 'not a message substring fallback';
    unlike $sql, qr/trk/, 'value never interpolated';
    is_deeply bind_values($bind), ['trk'], 'value bound as-is (case preserved)';
};

subtest 'pod:x* is a LIKE with escaped metacharacters' => sub {
    my ($sql, $bind) = compile('pod:api_v2-*');
    like $sql, qr/\(pod LIKE \{p_kql_0:String\}\)/, 'wildcard compiles to LIKE';
    is_deeply bind_values($bind), ['api\\_v2-%'], '_ escaped, * becomes %';
};

subtest 'quoted wildcard is literal' => sub {
    my ($sql, $bind) = compile('container:"side*car"');
    like $sql, qr/container = \{p_kql_0:String\}/, 'quoted * is equality';
    is_deeply bind_values($bind), ['side*car'], 'literal asterisk';
};

subtest 'NOT / AND / OR compose with k8s fields' => sub {
    my ($sql, $bind, $err) = compile('namespace:trk AND NOT (pod:web-* OR container:istio-proxy)');
    is $err, undef, 'parses';
    like $sql, qr/\(\(namespace = \{p_kql_0:String\}\) AND \(NOT \(\(pod LIKE \{p_kql_1:String\}\) OR \(container = \{p_kql_2:String\}\)\)\)\)/,
        'precedence preserved in the emitted SQL';
    is_deeply bind_values($bind), ['trk', 'web-%', 'istio-proxy'], 'three bound values';
};

subtest 'search box treats k8s field syntax as KQL' => sub {
    ok looks_like_kql('namespace:trk'), 'namespace:trk is KQL';
    ok looks_like_kql('pod:api-*'), 'pod:api-* is KQL';
    ok looks_like_kql('level:error container:app'), 'container: inside a longer query';
    ok !looks_like_kql('namespace: default was deleted'), 'space after colon stays literal text';
    my ($plan, $err) = plan_search_query('namespace:trk');
    is $err, undef, 'no error';
    is $plan->{kql}{field}, 'namespace', 'planned as a namespace term';
};

subtest 'AI search-bar validator (#98) accepts the k8s fields' => sub {
    is search_bar_query('namespace:trk AND pod:api-*'), 'namespace:trk AND pod:api-*', 'namespace + pod accepted';
    is search_bar_query('container:nginx'), 'container:nginx', 'container accepted';
    is search_bar_query('podname:x'), undef, 'a near-miss field is still rejected';
};

# ============================================
# /api/stats/fields/<field> — namespace/pod/container, current query applied
# ============================================
{
    package FacetStorage;
    sub new { bless { calls => [] }, $_[0] }
    sub field_stats {
        my ($s, $field, %p) = @_;
        push @{ $s->{calls} }, { field => $field, %p };
        return [ { value => 'trk', count => 7 } ];
    }

    package FacetReq;
    sub new { bless { p => $_[1], h => {} }, $_[0] }
    sub param { $_[0]{p}{$_[1]} }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub res { $_[0] }
    sub headers { $_[0] }
    sub header { $_[0]{h}{$_[1]} = $_[2] if @_ > 2; $_[0]{h}{$_[1]} }
    sub app { $_[0] }
    sub log { $_[0] }
    sub error { }
    sub stash { {} }
    sub session { {} }
}

subtest 'facet endpoint accepts namespace, pod, container with the host shape' => sub {
    for my $field (qw(namespace pod container)) {
        my $st   = FacetStorage->new;
        my $ctrl = Purl::API::Controller::Stats->new(storage => $st);
        my $c    = FacetReq->new({ field => $field, range => '1h' });
        $ctrl->field_stats($c);
        is $c->{rendered}{status}, undef, "$field: not an error";
        is_deeply $c->{rendered}{json}, { field => $field, values => [ { value => 'trk', count => 7 } ] },
            "$field: { field, values: [{value,count}] }";
        is $st->{calls}[0]{field}, $field, "$field: storage asked for that column";
        ok $st->{calls}[0]{from} && $st->{calls}[0]{to}, "$field: time range applied";
    }
};

subtest 'facet endpoint applies the current search query' => sub {
    my $st   = FacetStorage->new;
    my $ctrl = Purl::API::Controller::Stats->new(storage => $st);
    my $c    = FacetReq->new({ field => 'pod', q => 'namespace:trk AND level:error' });
    $ctrl->field_stats($c);
    my $kql = $st->{calls}[0]{kql};
    is ref $kql, 'HASH', 'KQL AST handed to storage';
    is $kql->{op}, 'and', 'the whole expression, not a fragment';

    # Plain text narrows facets too.
    my $c2 = FacetReq->new({ field => 'pod', q => 'connection refused' });
    $ctrl->field_stats($c2);
    is $st->{calls}[1]{query}, 'connection refused', 'literal text becomes a message filter';

    # A different query must not be answered from the first query's cache entry.
    is $c2->header('X-Cache'), 'MISS', 'cache keyed by query';
};

subtest 'facet endpoint rejects broken KQL with 400 and never queries' => sub {
    my $st   = FacetStorage->new;
    my $ctrl = Purl::API::Controller::Stats->new(storage => $st);
    my $c    = FacetReq->new({ field => 'namespace', q => 'namespace:trk AND (' });
    $ctrl->field_stats($c);
    is $c->{rendered}{status}, 400, '400 on a syntax error';
    is scalar @{ $st->{calls} }, 0, 'storage not called';
};

subtest 'facet endpoint still rejects unknown fields' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => FacetStorage->new);
    for my $field ('namespaces', 'pod;DROP', 'meta.namespace\'') {
        my $c = FacetReq->new({ field => $field });
        $ctrl->field_stats($c);
        is $c->{rendered}{status}, 400, "'$field' rejected";
    }
};

subtest 'storage whitelists the k8s columns for facets' => sub {
    my $q = MockCH->new;
    is $q->_validate_field($_), $_, "$_ allowed" for qw(namespace pod container);
};

done_testing;

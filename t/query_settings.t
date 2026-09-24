#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Storage::ClickHouse;

# ============================================
# #108 query settings: the per-query memory guard, and the optional
# version-dependent settings probed once per PROCESS — a probe made before
# prefork's fork (schema init runs there) must not be inherited by workers.
# ============================================

my @probes;
{
    no warnings 'redefine';
    *Purl::Storage::ClickHouse::_init_schema = sub { 1 };
    *Purl::Storage::ClickHouse::_query = sub {
        my ($self, $sql) = @_;
        push @probes, $sql;
        return "query_plan_max_limit_for_lazy_materialization\n";
    };
}

my $st = Purl::Storage::ClickHouse->new(max_query_memory => 400);
my $s  = $st->_query_settings;
like $s, qr/(?:^|&)max_memory_usage=400(?:&|$)/, 'max_memory_usage sent';
like $s, qr/max_bytes_before_external_sort=100(?:&|$)/, 'sort spills at a quarter';
like $s, qr/max_bytes_before_external_group_by=100(?:&|$)/, 'group by spills at a quarter';
like $s, qr/query_plan_max_limit_for_lazy_materialization=10000/, 'supported optional setting sent';
is scalar @probes, 1, 'server probed once';

$st->_query_settings for 1 .. 3;
is scalar @probes, 1, 'not re-probed in the same process';

# What a forked worker sees: the parent's cache, under the parent's pid.
$st->_supported_optional_settings->{pid} = $$ + 1;
$st->_query_settings;
is scalar @probes, 2, 'a different process probes for itself';

my $off = Purl::Storage::ClickHouse->new(max_query_memory => 0)->_query_settings;
unlike $off, qr/max_memory_usage/, 'max_query_memory=0 leaves memory to the server profile';

{
    no warnings 'redefine';
    local *Purl::Storage::ClickHouse::_query = sub { return "\n" };
    my $old = Purl::Storage::ClickHouse->new->_query_settings;
    unlike $old, qr/lazy_materialization/, 'setting omitted when the server does not list it';
}

subtest 'failed probe backs off instead of probing on every query' => sub {
    my $calls = 0;
    no warnings 'redefine';
    local *Purl::Storage::ClickHouse::_query = sub { $calls++; die "ClickHouse error: 599 - refused\n" };
    my $st = Purl::Storage::ClickHouse->new;
    $st->_query_settings for 1 .. 5;
    is $calls, 1, 'one probe for five queries while the server is down';
    $st->_optional_probe_retry_at(0);    # 30 s later
    $st->_query_settings;
    is $calls, 2, 'probes again once the back-off has passed';
};

subtest 'PURL_CLICKHOUSE_MAX_QUERY_MEMORY is validated' => sub {
    require Purl::API::Server::Builders;
    my @warn;
    local $SIG{__WARN__} = sub { push @warn, @_ };
    for my $case (['1073741824', 1073741824], ['0', 0], ['', 268435456],
                  ['1g', 268435456], ['-5', 268435456], ['12.5', 268435456]) {
        local $ENV{PURL_CLICKHOUSE_MAX_QUERY_MEMORY} = $case->[0];
        is Purl::API::Server::Builders::_max_query_memory({}), $case->[1], "'$case->[0]' => $case->[1]";
    }
    is scalar(grep { /not a whole number/ } @warn), 3, 'each invalid value warns';
    local $ENV{PURL_CLICKHOUSE_MAX_QUERY_MEMORY};
    delete $ENV{PURL_CLICKHOUSE_MAX_QUERY_MEMORY};
    is Purl::API::Server::Builders::_max_query_memory({ max_query_memory => 5000 }), 5000,
        'settings.json value used when ENV is unset';
};

done_testing;

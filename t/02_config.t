#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'lib';
use Purl::Config;

# Test configuration loading
subtest 'Config loading' => sub {
    my $config = Purl::Config->new;
    ok($config, 'Config object created');

    # Test default values using get method
    my $port = $config->get('server', 'port');
    ok(defined $port, 'Port is defined');
    is($port, 3000, 'Default port is 3000');

    my $ch_host = $config->get('clickhouse', 'host');
    ok(defined $ch_host, 'ClickHouse host is defined');

    my $ch_port = $config->get('clickhouse', 'port');
    ok(defined $ch_port, 'ClickHouse port is defined');

    my $ch_db = $config->get('clickhouse', 'database');
    ok(defined $ch_db, 'ClickHouse database is defined');
};

# Test environment variable overrides
subtest 'Environment overrides' => sub {
    local $ENV{PURL_CLICKHOUSE_HOST} = 'test-host';
    local $ENV{PURL_CLICKHOUSE_PORT} = '9001';

    my $config = Purl::Config->new;

    is($config->get('clickhouse', 'host'), 'test-host', 'ClickHouse host from env');
    is($config->get('clickhouse', 'port'), '9001', 'ClickHouse port from env');
};

# Test default values
subtest 'Default values' => sub {
    # Create config without env overrides for clickhouse settings
    local $ENV{PURL_CLICKHOUSE_HOST};
    local $ENV{PURL_CLICKHOUSE_PORT};
    local $ENV{PURL_CLICKHOUSE_DATABASE};
    delete $ENV{PURL_CLICKHOUSE_HOST};
    delete $ENV{PURL_CLICKHOUSE_PORT};
    delete $ENV{PURL_CLICKHOUSE_DATABASE};

    my $config = Purl::Config->new;

    is($config->get('server', 'port'), 3000, 'Default port is 3000');
    is($config->get('clickhouse', 'host'), 'localhost', 'Default CH host is localhost');
    is($config->get('clickhouse', 'port'), 8123, 'Default CH port is 8123');
    is($config->get('clickhouse', 'database'), 'purl', 'Default CH database is purl');
};

# Test get_section
subtest 'Get section' => sub {
    my $config = Purl::Config->new;

    my $ch_section = $config->get_section('clickhouse');
    ok($ch_section, 'ClickHouse section returned');
    ok(exists $ch_section->{host}, 'Section has host');
    ok(exists $ch_section->{port}, 'Section has port');
    ok(exists $ch_section->{database}, 'Section has database');
};

# Test is_from_env
subtest 'is_from_env' => sub {
    local $ENV{PURL_CLICKHOUSE_HOST} = 'env-host';

    my $config = Purl::Config->new;

    ok($config->is_from_env('clickhouse', 'host'), 'host is from env');
    ok(!$config->is_from_env('clickhouse', 'database'), 'database is not from env');
};

done_testing();

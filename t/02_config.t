#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempfile);

use_ok('Purl::Config');

# Default config (no file)
{
    local $ENV{PURL_CONFIG_FILE} = '/nonexistent/path/settings.json';
    my $cfg = Purl::Config->new;
    isa_ok($cfg, 'Purl::Config', 'constructor returns object');

    is($cfg->get('server', 'port'),     3000,        'default port is 3000');
    is($cfg->get('server', 'host'),     '0.0.0.0',   'default host is 0.0.0.0');
    is($cfg->get('retention', 'days'),  30,           'default retention 30 days');
    is($cfg->get('clickhouse', 'port'), 8123,         'default ClickHouse port 8123');
    is($cfg->get('clickhouse', 'user'), 'default',    'default CH user');
}

# ENV overrides
{
    local $ENV{PURL_CONFIG_FILE} = '/nonexistent/path/settings.json';
    local $ENV{PURL_PORT}        = '9000';
    local $ENV{PURL_HOST}        = '127.0.0.1';
    local $ENV{PURL_RETENTION_DAYS} = '7';
    local $ENV{PURL_API_KEYS}    = 'key1,key2,key3';

    my $cfg = Purl::Config->new;
    is($cfg->get('server', 'port'),    9000,      'ENV PURL_PORT overrides default');
    is($cfg->get('server', 'host'),    '127.0.0.1', 'ENV PURL_HOST overrides default');
    is($cfg->get('retention', 'days'), 7,          'ENV PURL_RETENTION_DAYS overrides default');

    # get() returns raw ENV string; Auth middleware does the split
    my $keys_raw = $cfg->get('auth', 'api_keys');
    is($keys_raw, 'key1,key2,key3', 'PURL_API_KEYS returned as raw string');
    my @keys = split /,/, $keys_raw;
    is(scalar @keys, 3,      'splitting raw value gives 3 keys');
    is($keys[0],     'key1', 'first key is key1');
    is($keys[2],     'key3', 'third key is key3');
}

# Config from JSON file
{
    my ($fh, $tmpfile) = tempfile(SUFFIX => '.json', UNLINK => 1);
    print $fh '{"server":{"port":8080,"host":"1.2.3.4"},"retention":{"days":14}}';
    close $fh;

    local $ENV{PURL_CONFIG_FILE} = $tmpfile;
    my $cfg = Purl::Config->new;
    is($cfg->get('server', 'port'), 8080,      'JSON file overrides default port');
    is($cfg->get('server', 'host'), '1.2.3.4', 'JSON file overrides default host');
    is($cfg->get('retention', 'days'), 14,     'JSON file overrides retention');
    # Non-overridden defaults remain
    is($cfg->get('clickhouse', 'port'), 8123,  'non-overridden clickhouse port stays default');
}

done_testing();

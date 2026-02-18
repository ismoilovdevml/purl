#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::XS qw(encode_json);

use lib 'lib';

# Create a temp config file
my $tmpdir = tempdir(CLEANUP => 1);
my $config_file = "$tmpdir/settings.json";

# Write test config
{
    open my $fh, '>', $config_file or die "Cannot write $config_file: $!";
    print $fh encode_json({
        auth => {
            users => {
                admin => 'hashed_pw',
                dev1  => 'hashed_pw',
                dev2  => 'hashed_pw',
            },
            roles => {
                admin => 'admin',
                dev1  => 'viewer',
                dev2  => 'operator',
            },
            namespace_scope => {
                dev1 => ['default', 'staging'],
                dev2 => ['production'],
            },
        },
    });
    close $fh;
}

# Test NamespaceScope middleware
use_ok('Purl::API::Middleware::NamespaceScope');
use_ok('Purl::Config');

my $settings = Purl::Config->new(config_file => $config_file);
my $ns = Purl::API::Middleware::NamespaceScope->new(settings => $settings);

# Admin gets empty array (all namespaces)
{
    my $allowed = $ns->get_allowed_namespaces('admin');
    is_deeply($allowed, [], 'Admin has no namespace restrictions');
}

# Viewer gets configured namespaces
{
    my $allowed = $ns->get_allowed_namespaces('dev1');
    is_deeply([sort @$allowed], ['default', 'staging'], 'dev1 has default + staging');
}

# Operator gets configured namespaces
{
    my $allowed = $ns->get_allowed_namespaces('dev2');
    is_deeply($allowed, ['production'], 'dev2 has production only');
}

# Unknown user gets empty (no restrictions by default)
{
    my $allowed = $ns->get_allowed_namespaces('unknown');
    is_deeply($allowed, [], 'Unknown user has no scope (empty = all for viewer without config)');
}

# check_namespace_access
{
    ok($ns->check_namespace_access('admin', 'anything'), 'Admin can access any namespace');
    ok($ns->check_namespace_access('dev1', 'default'), 'dev1 can access default');
    ok($ns->check_namespace_access('dev1', 'staging'), 'dev1 can access staging');
    ok(!$ns->check_namespace_access('dev1', 'production'), 'dev1 cannot access production');
    ok($ns->check_namespace_access('dev2', 'production'), 'dev2 can access production');
    ok(!$ns->check_namespace_access('dev2', 'staging'), 'dev2 cannot access staging');
}

# apply_namespace_filter
{
    my %params = (meta_field => 'namespace', meta_value => 'default');
    $ns->apply_namespace_filter('dev1', \%params);
    is($params{meta_value}, 'default', 'Allowed namespace passes through');
}

{
    my %params = (meta_field => 'namespace', meta_value => 'production');
    $ns->apply_namespace_filter('dev1', \%params);
    is($params{meta_value}, 'BLOCKED_NAMESPACE_ACCESS', 'Blocked namespace is rejected');
}

done_testing();

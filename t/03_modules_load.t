#!/usr/bin/env perl
# Smoke test: verify all core modules compile without errors
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

my @modules = qw(
    Purl::Config
    Purl::Util::Time
    Purl::API::Controller::Base
    Purl::API::Middleware::Auth
    Purl::API::Middleware::License
    Purl::Storage::ClickHouse
);

for my $module (@modules) {
    use_ok($module);
}

done_testing();

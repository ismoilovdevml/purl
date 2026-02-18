#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use JSON::XS qw(encode_json decode_json);

use lib 'lib';

# Test K8sAudit controller can be loaded
use_ok('Purl::API::Controller::K8sAudit');

# Test _now_iso returns valid format
{
    my $iso = Purl::API::Controller::K8sAudit::_now_iso();
    like($iso, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'ISO timestamp format');
}

done_testing();

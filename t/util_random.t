#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::Random qw(random_bytes random_hex);

# One CSPRNG reader for session ids, CSRF tokens, bcrypt salts and the
# generated admin password (they each had their own copy before #91).

is length(random_bytes(16)), 16, 'random_bytes returns exactly N bytes';
is length(random_bytes(1)),  1,  'even for one byte';
like random_hex(16), qr/\A[0-9a-f]{32}\z/, 'random_hex(16) is 32 hex chars';

my %seen = map { random_hex(16) => 1 } 1 .. 200;
is scalar(keys %seen), 200, '200 session-id sized values, no repeats';

done_testing();

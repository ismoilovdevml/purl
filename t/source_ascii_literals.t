#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use File::Find;

# ============================================
# REGRESSION (#107): "open a-circumflex euro service" in API error bodies.
#
# lib/ files do not `use utf8`, so a literal em dash in a string is three
# BYTES, not one character. Mojolicious then JSON-encodes (and Mojo::Log
# writes) those bytes as three Latin-1 characters -> double-encoded UTF-8.
# The circuit-breaker message, the ingest 503s, the SAML/API-key messages and
# the "ephemeral session secret" warning (Bootstrap) all had one.
#
# Rule: in a source file without `use utf8`, non-ASCII may appear in comments
# and POD only, never in code. Server messages are ASCII.
# ============================================

my @violations;

find({ no_chdir => 1, wanted => sub {
    return unless /\.pm\z/;
    my $file = $File::Find::name;
    open my $fh, '<:raw', $file or die "$file: $!";
    my @lines = <$fh>;
    close $fh;

    return if grep { /^\s*use\s+utf8\b/ } @lines;

    my $pod = 0;
    my $n   = 0;
    for my $line (@lines) {
        $n++;
        last if $line =~ /^__(?:END|DATA)__\b/;
        if ($line =~ /^=cut\b/) { $pod = 0; next }
        if ($line =~ /^=[a-zA-Z]/) { $pod = 1; next }
        next if $pod;
        next unless $line =~ /[^\x00-\x7F]/;

        # Drop a trailing comment. Rough (a '#' inside a string would end the
        # code early) but it can only under-report, never flag a comment.
        (my $code = $line) =~ s/(?:^|\s)#.*//s;
        push @violations, "$file:$n: $line" if $code =~ /[^\x00-\x7F]/;
    }
}}, "$Bin/../lib");

is scalar(@violations), 0, 'no non-ASCII byte literals in lib/ code'
    or diag "Non-ASCII in code (use ASCII, e.g. '-' for an em dash):\n", @violations;

done_testing;

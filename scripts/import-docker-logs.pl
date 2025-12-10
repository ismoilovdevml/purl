#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use Purl::Storage::ClickHouse;
use Purl::Parser::FormatDetector;
use Purl::Parser::Engine;
use Purl::Parser::Normalizer;
use Time::Piece;
use Getopt::Long;

my $container = shift @ARGV;

unless ($container) {
    die "Usage: $0 <container_name_or_id>\n";
}

print "Importing logs from container: $container\n";

# Initialize ClickHouse storage
my $storage = Purl::Storage::ClickHouse->new(
    host     => $ENV{PURL_CLICKHOUSE_HOST} // 'localhost',
    port     => $ENV{PURL_CLICKHOUSE_PORT} // 8123,
    database => $ENV{PURL_CLICKHOUSE_DATABASE} // 'purl',
);

my $detector = Purl::Parser::FormatDetector->new();
my $engine = Purl::Parser::Engine->new();
my $normalizer = Purl::Parser::Normalizer->new();

# Get logs from docker
my @logs = `docker logs $container 2>&1`;
my $count = 0;
my @batch;

for my $line (@logs) {
    chomp $line;
    next unless length $line;

    # Detect format
    my $format = $detector->detect_line($line);

    # Parse
    my $parsed = $engine->parse($line, $format);

    # Normalize
    my $normalized = $normalizer->normalize($parsed);
    $normalized->{service} //= $container;
    $normalized->{host} //= 'docker';

    push @batch, $normalized;
    $count++;

    # Batch insert every 100 logs
    if (@batch >= 100) {
        $storage->insert_batch(\@batch);
        $storage->flush();
        @batch = ();
        print "Imported $count logs...\n";
    }
}

# Insert remaining
if (@batch) {
    $storage->insert_batch(\@batch);
    $storage->flush();
}

print "Done! Imported $count logs from $container\n";

package Purl;
use strict;
use warnings;
use 5.024;

our $VERSION = '0.01';

1;

__END__

=head1 NAME

Purl - Universal Log Parser & Dashboard

=head1 SYNOPSIS

    # Start the collector
    purl collect --config /path/to/config.yaml

    # Start the web dashboard
    purl server --port 3000

    # Parse logs from stdin
    cat /var/log/nginx/access.log | purl parse --format nginx

=head1 DESCRIPTION

Purl is a universal log parser that automatically detects log formats,
normalizes them to a unified JSON schema, stores them in SQLite with
full-text search, and provides an OpenSearch Discover-like web dashboard.

=head1 FEATURES

=over 4

=item * Auto-detection of log formats (nginx, syslog, JSON, docker, etc.)

=item * Unified JSON schema for all logs

=item * SQLite storage with FTS5 full-text search

=item * KQL-like query language

=item * Real-time log tailing (live tail mode)

=item * Web dashboard with filtering, time ranges, and aggregations

=back

=head1 AUTHOR

Purl Contributors

=head1 LICENSE

MIT License

=cut

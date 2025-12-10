package Purl;
use strict;
use warnings;
use 5.024;

our $VERSION = '0.2.0';

1;

__END__

=head1 NAME

Purl - Log Aggregation Dashboard

=head1 SYNOPSIS

    # Start with Docker
    docker-compose --profile vector up -d

    # Open dashboard
    open http://localhost:3000

=head1 DESCRIPTION

Purl is a lightweight log aggregation dashboard that automatically
collects logs from Docker containers via Vector, stores them in
ClickHouse, and provides a web dashboard for searching and analysis.

=head1 FEATURES

=over 4

=item * Auto-collection from Docker/Kubernetes via Vector

=item * ClickHouse storage with MergeTree engine and TTL retention

=item * Web dashboard with search, filtering, and histogram

=item * Prometheus metrics at /api/metrics

=item * Basic Auth and API key authentication

=item * Rate limiting and query caching

=back

=head1 ARCHITECTURE

    Docker Containers --> Vector --> POST /api/logs --> ClickHouse
                                           |
                                           v
                                      Dashboard

=head1 API ENDPOINTS

    GET  /api/health    - Health check
    GET  /api/metrics   - Prometheus metrics
    GET  /api/logs      - Search logs
    POST /api/logs      - Ingest logs
    GET  /api/stats     - Database statistics
    WS   /api/logs/stream - Live log stream

=head1 AUTHOR

Purl Contributors

=head1 LICENSE

MIT License

=cut

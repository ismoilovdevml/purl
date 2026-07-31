package Purl::Util::IngestRoutes;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);

our @EXPORT_OK = qw(is_ingest_request);

# ============================================
# One definition of "this request is a log-ingest request".
#
# Two callers need the same answer and must not drift apart:
#   * Purl::API::Server — the ingest-bytes Prometheus counter, which is only
#     meaningful on the endpoints that actually accept logs.
#   * Purl::API::Middleware::Auth — Authorization: Bearer is accepted as an
#     alternative transport for an ingest API key on these routes ONLY, never
#     on the session-cookie dashboard routes.
#
# Ingest is POST-only on purpose: GET /api/logs shares its path with the ingest
# POST but is a search, and widening a *credential transport* to cover search
# is not what any of the ingest agents need.
# ============================================

my $INGEST_PATH = qr{^/api/(?:logs|v1/(?:otlp/logs|syslog|k8s-audit)|_bulk|[^/]+/_bulk)$};

sub is_ingest_request {
    my ($method, $path) = @_;

    return 0 unless defined $method && uc($method) eq 'POST';
    return 0 unless defined $path && length $path;

    # Mojolicious routes match with or without a trailing slash, so the auth
    # decision has to agree with the router rather than with the literal string.
    $path =~ s{/+\z}{} if $path ne '/';

    return $path =~ $INGEST_PATH ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::Util::IngestRoutes - Shared predicate for the log-ingest endpoints

=head1 SYNOPSIS

    use Purl::Util::IngestRoutes qw(is_ingest_request);

    if (is_ingest_request($c->req->method, $c->req->url->path->to_string)) {
        ...
    }

=head1 FUNCTIONS

=over 4

=item * is_ingest_request($method, $path) - true for a POST to an ingest route
(C</api/logs>, C</api/v1/otlp/logs>, C</api/v1/syslog>, C</api/v1/k8s-audit>,
C</api/_bulk>, C</api/E<lt>indexE<gt>/_bulk>). Undef-safe; returns 0/1.

=back

=cut

package Purl::API::Server::Hooks;
use strict;
use warnings;
use 5.024;

use Time::HiRes qw(time);
use Purl::Util::IngestRoutes qw(is_ingest_request);
use Purl::Util::Principal qw(principal_user);
use Purl::Util::ErrorResponse qw(exception_response);

# App-wide request hooks and helpers: security headers + CORS, request
# metrics/logging, and the audit_event helper. %args:
#   metrics           hashref of the per-worker request metrics (mutated)
#   auth_middleware   coderef returning the CURRENT Purl::API::Middleware::Auth
#   metrics_counters  coderef returning the CURRENT Purl::Metrics::Counters
#   storage           coderef returning the CURRENT storage (audit_event)
# The coderefs are read per request, not captured once, so the hooks always
# see what setup_routes() last installed — and, for storage, what a settings
# change last rebuilt (rebuild_storage replaces the object, not its contents).
sub install {
    my ($app, %args) = @_;
    my $metrics = $args{metrics};
    my $auth    = $args{auth_middleware};
    my $shared  = $args{metrics_counters};
    my $storage = $args{storage};

    # Security headers and CORS
    $app->hook(before_dispatch => sub {
        my ($c) = @_;
        my $start = time();
        $c->stash(request_start => $start);

        # Core security headers
        $c->res->headers->header('X-Content-Type-Options' => 'nosniff');
        $c->res->headers->header('X-Frame-Options' => 'SAMEORIGIN');
        $c->res->headers->header('X-XSS-Protection' => '1; mode=block');
        $c->res->headers->header('Referrer-Policy' => 'strict-origin-when-cross-origin');

        # Comprehensive Content-Security-Policy
        $c->res->headers->header('Content-Security-Policy' => join('; ',
            "default-src 'self'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob:",
            "font-src 'self' data:",
            "connect-src 'self' ws: wss:",
            "frame-ancestors 'none'",
            "base-uri 'self'",
            "form-action 'self'",
        ));

        # Transport security
        $c->res->headers->header('Strict-Transport-Security' => 'max-age=31536000; includeSubDomains; preload');

        # Permissions policy — disable sensitive browser features
        $c->res->headers->header('Permissions-Policy' => 'camera=(), microphone=(), geolocation=(), payment=()');

        # Cross-origin isolation headers
        $c->res->headers->header('Cross-Origin-Opener-Policy' => 'same-origin');
        $c->res->headers->header('Cross-Origin-Resource-Policy' => 'same-origin');

        # Cross-Origin-Embedder-Policy only for non-static (API) requests
        my $path = $c->req->url->path->to_string;
        unless ($path =~ m{^/(?:assets|favicon|static)/} || $path =~ m{\.\w+$}) {
            $c->res->headers->header('Cross-Origin-Embedder-Policy' => 'require-corp');
        }

        # CORS — whitelist-based origin checking
        my $allowed_origins_str = $ENV{PURL_ALLOWED_ORIGINS}
            // 'http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173';
        my %allowed_origins = map { $_ => 1 } split(/\s*,\s*/, $allowed_origins_str);

        my $origin = $c->req->headers->header('Origin') // '';
        if ($origin && $allowed_origins{$origin}) {
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        } elsif ($origin && $origin =~ /^https?:\/\/(?:localhost|127\.0\.0\.1)(:\d+)?$/) {
            # Always allow localhost variants for development
            $c->res->headers->header('Access-Control-Allow-Origin' => $origin);
            $c->res->headers->header('Access-Control-Allow-Credentials' => 'true');
        }
        # No Access-Control-Allow-Origin header = browser blocks the request
        $c->res->headers->header('Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, OPTIONS');
        $c->res->headers->header('Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-API-Key, X-CSRF-Token');

        if ($c->req->method eq 'OPTIONS') {
            $c->render(text => '', status => 200);
            return;
        }

        $metrics->{requests_total}++;
        $path = $c->req->url->path->to_string;
        $path =~ s/\/[0-9a-f-]{36}/:id/g;
        $metrics->{requests_by_path}{$path}++;
    });

    # Request logging and metrics collection
    $app->hook(after_dispatch => sub {
        my ($c) = @_;
        my $start = $c->stash('request_start');
        my $duration = $start ? time() - $start : 0;
        my $duration_ms = $duration * 1000;

        $metrics->{query_duration_sum} += $duration;
        $metrics->{query_count}++;

        # Track latencies for percentile calculation using O(1) circular buffer
        my $idx = $metrics->{latency_index} % 1000;
        $metrics->{latencies}[$idx] = $duration_ms;
        $metrics->{latency_index}++;
        $metrics->{latency_count}++ if $metrics->{latency_count} < 1000;

        # Track bytes
        my $req_size = length($c->req->body // '');
        my $res_size = length($c->res->body // '');
        $metrics->{bytes_in} += $req_size;
        $metrics->{bytes_out} += $res_size;

        my $method = $c->req->method;
        my $path = $c->req->url->path->to_string;
        my $status = $c->res->code // 0;
        my $auth_middleware = $auth->();
        my $ip = ($auth_middleware ? $auth_middleware->client_ip($c) : $c->tx->remote_address) // '-';

        my $log_level = $status >= 500 ? 'error' : ($status >= 400 ? 'warn' : 'info');
        $c->app->log->$log_level(sprintf("%s - %s %s %d %.2fms", $ip, $method, $path, $status, $duration_ms));

        $metrics->{errors_total}++ if $status >= 400;

        # Mirror into the SHARED counters that /api/metrics exports. The
        # per-worker metrics above stay as-is for /api/metrics/json (per-worker
        # latency percentiles need the local circular buffer), but anything
        # Prometheus scrapes has to be fleet-wide or the numbers are fiction
        # under prefork.
        if (my $metrics_counters = $shared->()) {
            $metrics_counters->record_request(
                method      => $method,
                status      => $status,
                duration_ms => $duration_ms,
            );
            # Ingest volume, measured on the endpoints that actually accept
            # logs — total bytes_in would be dominated by dashboard traffic.
            $metrics_counters->record_ingest_bytes($req_size)
                if is_ingest_request($method, $path);
        }
    });

    # An exception that escapes a handler (outside safe_execute) under /api is
    # answered in the API error shape, never Mojolicious's HTML exception page
    # nor its text (#107). Mojo still logs the exception itself; ours adds the
    # line carrying the request id the client is given.
    #
    # Mojolicious puts the exception in the stash before rendering it, whichever
    # of its html/json/txt exception pages it picks; in development mode the
    # json and txt ones carry the raw message, so all three are replaced.
    $app->hook(before_render => sub {
        my ($c, $args) = @_;
        my $e = $c->stash('exception') // return;
        return unless $c->req->url->path->to_string =~ m{\A/api(?:/|\z)};
        my ($status, $body) = exception_response($c, $e);
        delete @$args{qw(template text format handler)};
        $args->{json}   = $body;
        $args->{status} = $status;
        return;
    });

    # Audit event helper — fire-and-forget, never breaks the app. A failure is
    # logged, not swallowed: an audit trail that silently records nothing is
    # what #101 was.
    $app->helper(audit_event => sub {
        my ($c, %event) = @_;
        my $ok = eval {
            my $auth_middleware = $auth->();
            my $store = $storage ? $storage->() : undef;
            die "no storage wired\n" unless $store;
            $store->log_audit_event({
                actor         => $event{actor} // principal_user($c) // 'system',
                action        => $event{action},
                resource_type => $event{resource_type} // '',
                resource_id   => $event{resource_id}   // '',
                details       => $event{details}        // '',
                ip_address    => ($auth_middleware ? $auth_middleware->client_ip($c) : $c->tx->remote_address) // '',
                status        => $event{status}         // 'success',
            });
            1;
        };
        $c->app->log->warn('audit_event(' . ($event{action} // '?') . ") not recorded: $@")
            unless $ok;
        return;
    });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Server::Hooks - security headers, CORS, request metrics/logging
and the audit_event helper for the Purl Mojolicious app

=cut

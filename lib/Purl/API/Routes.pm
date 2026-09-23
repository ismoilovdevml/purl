package Purl::API::Routes;
use strict;
use warnings;
use 5.024;

use Purl::API::Routes::System;
use Purl::API::Routes::Logs;
use Purl::API::Routes::Management;
use Purl::API::Routes::Integrations;
use Purl::API::Routes::LiveTail;
use Purl::Util::Principal qw(principal);
use Purl::Util::ErrorResponse qw(message_response);

# Route table of the Purl API. Mojolicious matches routes in DEFINITION ORDER,
# so the area modules below are registered in a fixed sequence and the JSON 404
# catch-all is always last under /api.
#
# %deps:
#   controllers      hashref of controller instances, keyed by area name
#   auth_middleware  coderef returning the CURRENT Purl::API::Middleware::Auth
#   metrics          per-worker request metrics hashref (errors_total is bumped)
#   websockets       arrayref of open live-tail sockets
#   broadcaster      coderef returning the live-tail broadcaster (may be undef)
sub register {
    my ($app, %deps) = @_;
    my $auth    = $deps{auth_middleware};
    my $metrics = $deps{metrics};

    my %r = (
        %deps,
        rate_limited => sub { _render_rate_limited($metrics, @_) },
    );

    my $api = $app->routes->under('/api');

    # Protected routes middleware
    my $protected = $api->under('/' => sub {
        my ($c) = @_;
        my $path = $c->req->url->path->to_string;
        return 1 if $path =~ m{^/api/(health(/live|/ready)?|metrics)$};

        my $auth_middleware = $auth->();
        my $ip = $auth_middleware->client_ip($c);

        # Rate limiting via middleware
        return _render_rate_limited($metrics, $c, 'Rate limit exceeded',
            $auth_middleware->rate_limit_retry_after)
            unless $auth_middleware->check_rate_limit($ip);

        # Add rate limit headers
        $c->res->headers->header('X-RateLimit-Limit' => $auth_middleware->rate_limit_max);
        $c->res->headers->header('X-RateLimit-Remaining' => $auth_middleware->get_rate_limit_remaining($ip));

        # Auth check via middleware
        unless ($auth_middleware->check_auth($c)) {
            _render_gate_error($c, 'Unauthorized', 401);
            $metrics->{errors_total}++;
            return 0;
        }

        # CSRF protection for cookie-authenticated (browser) mutating requests.
        # API-key / basic-auth clients and read-only methods are exempt.
        unless ($auth_middleware->check_csrf($c)) {
            _render_gate_error($c, 'CSRF token missing or invalid', 403, csrf => \1);
            $metrics->{errors_total}++;
            return 0;
        }

        # Block access if password change required (except for the change-password endpoint itself)
        if (principal($c)->{must_change_password} && $path !~ m{^/api/auth/(change-password|me|logout)$}) {
            _render_gate_error($c, 'Password change required', 403,
                password_change_required => \1);
            return 0;
        }

        return 1;
    });

    $r{api}       = $api;
    $r{protected} = $protected;

    Purl::API::Routes::System::register(%r);
    Purl::API::Routes::Logs::register(%r);
    Purl::API::Routes::Management::register(%r);
    Purl::API::Routes::Integrations::register(%r);
    Purl::API::Routes::LiveTail::register(%r);

    # Unmatched /api/* (any method) is a JSON 404, never the SPA index (#84).
    # Must stay the LAST /api route: Mojolicious matches in definition order.
    $api->any('/*api_path' => { api_path => '' } => sub {
        my ($c) = @_;
        _render_gate_error($c, 'Not found', 404);
    });

    # SPA fallback (non-API paths only — /api/* is caught above)
    $app->routes->get('/*catchall' => { catchall => '' } => sub {
        my ($c) = @_;
        $c->reply->static('index.html');
    });

    return;
}

# The gate's own refusals, in the one API error shape ({error, code,
# request_id}, Purl::Util::ErrorResponse) plus any flags the UI keys on.
sub _render_gate_error {
    my ($c, $message, $status, %extra) = @_;
    my ($code, $body) = message_response($c, $message, $status);
    return $c->render(json => { %$body, %extra }, status => $code);
}

# One 429 shape for every limiter: JSON body + Retry-After header carrying the
# seconds actually left in the caller's window, counted as an error.
sub _render_rate_limited {
    my ($metrics, $c, $error, $retry_after) = @_;
    $c->res->headers->header('Retry-After' => $retry_after);
    _render_gate_error($c, $error, 429, retry_after => $retry_after);
    $metrics->{errors_total}++;
    return 0;
}

1;

__END__

=head1 NAME

Purl::API::Routes - the Purl API route table: the /api auth gate, the
per-area route modules (Purl::API::Routes::*) and the 404 / SPA fallbacks

=cut

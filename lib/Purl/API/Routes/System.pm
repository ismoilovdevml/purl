package Purl::API::Routes::System;
use strict;
use warnings;
use 5.024;

# Public endpoints (health, metrics, CSRF token, login/logout, SSO) plus the
# one protected auth route. See Purl::API::Routes for %deps.
sub register {
    my (%deps) = @_;
    my ($api, $protected) = @deps{qw(api protected)};
    my $ctl        = $deps{controllers};
    my $sys        = $ctl->{system};
    my $auth       = $ctl->{auth};
    my $sso_status = $ctl->{sso_status};

    # ============================================
    # Public endpoints (no auth)
    # ============================================
    $api->get('/csrf-token' => sub { my ($c) = @_; $auth->csrf_token($c) });
    $api->get('/health' => sub { my ($c) = @_; $sys->health($c) });
    # Split probes for Kubernetes. /live must NEVER depend on ClickHouse:
    # pointing a livenessProbe at a DB-backed endpoint turns a database outage
    # into a fleet-wide CrashLoopBackOff. /ready carries the dependency check.
    $api->get('/health/live'  => sub { my ($c) = @_; $sys->health_live($c) });
    $api->get('/health/ready' => sub { my ($c) = @_; $sys->health_ready($c) });
    $api->get('/metrics' => sub { my ($c) = @_; $sys->metrics($c) });
    $api->get('/metrics/json' => sub { my ($c) = @_; $sys->metrics_json($c) });

    # Auth endpoints (public - no auth required)
    $api->post('/auth/login' => sub { my ($c) = @_; $auth->login($c) });
    $api->post('/auth/logout' => sub { my ($c) = @_; $auth->logout($c) });
    $api->get('/auth/me' => sub { my ($c) = @_; $auth->me($c) });

    # Password change (requires auth — protected route)
    $protected->post('/auth/change-password' => sub { my ($c) = @_; $auth->change_password($c) });

    # SSO/SAML 2.0 endpoints (public — no auth required)
    $api->get('/auth/sso/login'     => sub { my ($c) = @_; $auth->sso_login($c) });
    $api->post('/auth/sso/callback' => sub { my ($c) = @_; $auth->sso_callback($c) });
    $api->get('/auth/sso/metadata'  => sub { my ($c) = @_; $auth->sso_metadata($c) });
    # Is SSO on? The login page uses this to show the SSO button.
    $api->get('/auth/sso/status'    => sub { my ($c) = @_; $sso_status->status($c) });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Routes::System - health, metrics, CSRF, login/logout and SSO routes

=cut

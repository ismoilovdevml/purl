package Purl::API::Controller::SSO;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::Session qw(start_session auth_section);
use namespace::clean;

extends 'Purl::API::Controller::Base';

# SAML middleware; undef when SSO is disabled. Read-write because Server.pm
# swaps it in place when an admin saves new SSO settings (rebuild_saml).
has 'saml_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

# The SAML SP flow: redirect to the IdP, consume its assertion, publish our
# metadata. A successful assertion opens the same kind of session a password
# login does (Purl::Util::Session::start_session). Whether SSO is on at all is
# answered separately by Purl::API::Controller::SSOStatus.

# SSO/SAML 2.0 — Initiate SP login redirect
sub sso_login {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw && $saml_mw->is_available()) {
            $self->render_error($c, 'SSO is not configured or unavailable', 503);
            return;
        }

        my $relay_state = $c->param('redirect') // '/';

        my $result = $saml_mw->build_authn_request($relay_state);
        unless ($result->{success}) {
            $c->app->log->warn("SSO: build_authn_request failed: $result->{error}");
            $self->render_error($c, 'Failed to initiate SSO login', 500);
            return;
        }

        $c->redirect_to($result->{redirect_url});
    });
}

# SSO/SAML 2.0 — Assertion Consumer Service (receives IdP POST)
sub sso_callback {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $self->render_error($c, 'SSO not configured', 503);
            return;
        }

        my $saml_response = $c->param('SAMLResponse');
        unless ($saml_response && length $saml_response) {
            $self->render_error($c, 'Missing SAMLResponse parameter', 400);
            return;
        }

        my $relay_state = $c->param('RelayState') // '/';

        my $result = $saml_mw->validate_response($saml_response, $relay_state);

        unless ($result->{success}) {
            $c->app->log->warn("SSO: SAML validation failed: $result->{error}");
            # Redirect to login page with error
            $c->redirect_to('/?error=sso_failed');
            return;
        }

        # Create session — same shape as LDAP session
        my @saml_groups = @{ $result->{groups} // [] };

        # Detect admin role from SAML groups
        my $saml_mw_cfg = $saml_mw->config // {};
        my $admin_group = $saml_mw_cfg->{admin_group} // 'admins';
        my $is_admin = grep { lc($_) eq lc($admin_group) } @saml_groups;

        start_session($c, auth_section($self->settings),
            username    => $result->{username},
            auth_method => 'saml',
            saml_groups => \@saml_groups,
            role        => $is_admin ? 'admin' : 'viewer',
            ($is_admin ? (is_admin => 1) : ()),
        );

        # Safe redirect — only allow relative paths
        my $safe_redirect = '/';
        if ($relay_state && $relay_state =~ m{^/[^/]}) {
            $safe_redirect = $relay_state;
        }

        $c->redirect_to($safe_redirect);
    });
}

# SSO/SAML 2.0 — SP metadata XML
sub sso_metadata {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $self->render_error($c, 'SSO not configured', 404);
            return;
        }

        my $xml = eval { $saml_mw->generate_metadata() };
        if ($@ || !$xml) {
            $self->render_error($c, 'Failed to generate SAML metadata', 500);
            return;
        }

        $c->res->headers->content_type('application/xml; charset=utf-8');
        $c->render(text => $xml);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::SSO - SAML 2.0 SSO login, assertion consumer and SP
metadata

=head1 DESCRIPTION

C<GET /api/auth/sso/login>, C<POST /api/auth/sso/callback> and
C<GET /api/auth/sso/metadata>. All public: they run before anyone is signed in.

=cut

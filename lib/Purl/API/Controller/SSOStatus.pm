package Purl::API::Controller::SSOStatus;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

extends 'Purl::API::Controller::Base';

# SAML middleware; undef when SSO is disabled. Read-write because Server.pm
# swaps it in place when an admin saves new SSO settings (rebuild_saml).
has 'saml_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

# Public: the login page asks this before anyone is signed in, to decide
# whether to offer the "Sign in with SSO" button. Enabled means the same
# thing sso_login checks before it redirects: the middleware exists (SSO is
# switched on) AND it is fully configured.
sub status {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        my $enabled = $saml_mw && eval { $saml_mw->is_available() };
        $c->render(json => { enabled => $enabled ? \1 : \0 });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::SSOStatus - Public SSO availability probe

=head1 DESCRIPTION

C<GET /api/auth/sso/status> returns C<{"enabled": true|false}>: true only when
SAML SSO is enabled and fully configured. No authentication required.

=cut

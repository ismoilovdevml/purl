package Purl::API::Controller::Settings::SSO;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(strip_location);
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Settings manager (Purl::Config instance)
has 'settings' => (
    is       => 'ro',
    required => 1,
);

has 'saml_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

has 'rebuild_saml' => (
    is      => 'ro',
    default => sub { sub {} },
);

# ============================================
# SSO/SAML Settings
# ============================================

sub get_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $saml = $self->settings->get_section('saml') // {};

        # Never expose private key in plaintext
        my $safe = { %$saml };
        $safe->{sp_key} = $safe->{sp_key} ? '********' : '';

        $c->render(json => {
            config   => $safe,
            from_env => $self->env_flags('saml'),
        });
    });
}

sub update_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Guard before validation — see Settings::LDAP::update_ldap.
        # '********' is what get_sso hands the UI for sp_key.
        return if $self->reject_env_managed($c, 'saml', $body,
            unchanged_marker => '********');

        # Validate required fields when enabling
        if ($body->{enabled}) {
            for my $field (qw(entity_id idp_entity_id idp_sso_url idp_cert acs_url)) {
                unless ($body->{$field} && length $body->{$field}) {
                    $self->render_error($c, "Field '$field' is required when SSO is enabled", 400);
                    return;
                }
            }

            unless ($body->{acs_url} =~ m{^https?://}) {
                $self->render_error($c, 'ACS URL must start with http:// or https://', 400);
                return;
            }

            unless ($body->{idp_sso_url} =~ m{^https?://}) {
                $self->render_error($c, 'IdP SSO URL must start with http:// or https://', 400);
                return;
            }
        }

        my $current = $self->settings->get_section('saml') // {};

        my @updatable = qw(enabled entity_id idp_entity_id idp_sso_url idp_slo_url
                           idp_cert acs_url name_id_format sign_requests sp_cert
                           username_attr groups_attr allowed_groups force_authn);

        for my $key (@updatable) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        # Only update sp_key if explicitly provided and not masked
        if (exists $body->{sp_key} && $body->{sp_key} ne '********') {
            $current->{sp_key} = $body->{sp_key};
        }

        if ($self->settings->set_section('saml', $current)) {
            $self->rebuild_saml->();
            $c->audit_event(action => 'update_settings', resource_type => 'settings', resource_id => 'saml');
            $c->render(json => { status => 'ok', message => 'SSO settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save SSO settings', 500);
        }
    });
}

sub test_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $c->render(json => {
                success => 0,
                error   => 'SSO middleware not initialized. Save and enable settings first.',
            });
            return;
        }

        my $available = eval { $saml_mw->is_available() };
        if ($@ || !$available) {
            $c->render(json => {
                success => 0,
                error   => $@ ? "Configuration error: " . strip_location($@) : 'SSO is not properly configured (missing required fields)',
            });
            return;
        }

        # Test that we can build an AuthnRequest
        my $test_result = eval { $saml_mw->build_authn_request('test') };
        if ($@ || !$test_result || !$test_result->{success}) {
            $c->render(json => {
                success => 0,
                error   => $test_result->{error} // ($@ ? strip_location($@) : undef) // 'Failed to build test AuthnRequest',
            });
            return;
        }

        $c->render(json => {
            success => 1,
            message => 'SSO configuration is valid. SP initialized and AuthnRequest generated successfully.',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::SSO - SSO / SAML 2.0 settings and configuration test

=cut

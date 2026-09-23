package Purl::API::Controller::Settings::LDAP;
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

# Callback to rebuild LDAP middleware after config change
has 'rebuild_ldap' => (
    is      => 'ro',
    default => sub { sub {} },
);

# LDAP middleware for test connection
has 'ldap_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

# ============================================
# LDAP/AD Configuration
# ============================================

sub get_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $ldap = $self->settings->get_section('ldap') // {};

        # Never expose bind password
        my $safe = { %$ldap };
        $safe->{bind_password} = $safe->{bind_password} ? '********' : '';

        $c->render(json => {
            config   => $safe,
            from_env => $self->env_flags('ldap'),
        });
    });
}

sub update_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # BEFORE field validation, deliberately: "this value is not yours to
        # change" outranks "this value is malformed". Validating first tells an
        # admin to fix a field that the environment owns and they cannot edit
        # at all.
        #
        # '********' is what get_ldap hands the UI for bind_password; sending it
        # back means "unchanged", not an attempted edit.
        return if $self->reject_env_managed($c, 'ldap', $body,
            unchanged_marker => '********');

        # Validate required fields when enabling
        if ($body->{enabled}) {
            for my $field (qw(server bind_dn search_base)) {
                unless ($body->{$field}) {
                    $self->render_error($c, "Field '$field' is required when LDAP is enabled", 400);
                    return;
                }
            }

            # Validate server URL format
            unless ($body->{server} =~ m{^ldaps?://}) {
                $self->render_error($c, "Server URL must start with ldap:// or ldaps://", 400);
                return;
            }
        }

        my $current = $self->settings->get_section('ldap') // {};

        my @updatable = qw(enabled server port bind_dn search_base search_filter
                           tls_enabled tls_verify timeout mode user_attr mail_attr
                           group_attr base_dn);

        for my $key (@updatable) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        # Only update password if explicitly provided and not masked
        if (exists $body->{bind_password} && $body->{bind_password} ne '********') {
            $current->{bind_password} = $body->{bind_password};
        }

        # Auto-set AD defaults when mode=ad
        if (($body->{mode} // '') eq 'ad') {
            $current->{user_attr}  //= 'sAMAccountName';
            $current->{group_attr} //= 'memberOf';
            $current->{mail_attr}  //= 'mail';
        }

        if ($self->settings->set_section('ldap', $current)) {
            $self->rebuild_ldap->();
            $c->audit_event(action => 'update_settings', resource_type => 'settings', resource_id => 'ldap');
            $c->render(json => { status => 'ok', message => 'LDAP settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save LDAP settings', 500);
        }
    });
}

sub test_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $ldap_mw = $self->ldap_middleware;
        unless ($ldap_mw) {
            $c->render(json => {
                success => 0,
                error   => 'LDAP middleware not initialized. Save settings first.',
            });
            return;
        }

        my $available = eval { $ldap_mw->is_available() };
        if ($@ || !$available) {
            $c->render(json => {
                success => 0,
                error   => $@ ? "Connection error: " . strip_location($@) : q{LDAP server unreachable},
            });
            return;
        }

        $c->render(json => {
            success => 1,
            message => 'LDAP server reachable and service account bind successful.',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::LDAP - LDAP / Active Directory settings and connection test

=cut

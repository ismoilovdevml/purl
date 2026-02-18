package Purl::API::Middleware::NamespaceScope;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

has 'settings' => (is => 'ro', required => 1);

# ============================================
# Namespace-scoped RBAC enforcement
#
# Restricts log visibility based on user's
# allowed namespaces. Admin users see all.
#
# Config format in settings.json:
#   auth.namespace_scope.user1: ["default", "staging"]
#   auth.namespace_scope.admin: []  (empty = all namespaces)
# ============================================

sub get_allowed_namespaces {
    my ($self, $username) = @_;
    return [] unless defined $username && $username ne '';

    my $auth_section = $self->settings->get_section('auth') // {};
    my $scope = $auth_section->{namespace_scope} // {};

    # Get user's role
    my $roles = $auth_section->{roles} // {};
    my $role  = $roles->{$username} // 'viewer';

    # Admin always sees everything
    return [] if $role eq 'admin';

    # Get user-specific namespace list
    my $namespaces = $scope->{$username} // [];
    return ref $namespaces eq 'ARRAY' ? $namespaces : [];
}

sub apply_namespace_filter {
    my ($self, $username, $params) = @_;
    return $params unless defined $username;

    my $allowed = $self->get_allowed_namespaces($username);
    return $params unless @$allowed;

    # If user already specified a namespace filter, validate it
    if ($params->{meta_field} && $params->{meta_field} eq 'namespace') {
        my $requested = $params->{meta_value} // '';
        my %allowed_set = map { $_ => 1 } @$allowed;
        unless ($allowed_set{$requested}) {
            # User requested a namespace they don't have access to
            $params->{meta_value} = 'BLOCKED_NAMESPACE_ACCESS';
        }
        return $params;
    }

    # No namespace filter specified — inject one
    # For multiple namespaces, we'll use the first one as primary
    # The actual multi-namespace support uses a WHERE IN clause
    $params->{_allowed_namespaces} = $allowed;
    return $params;
}

sub check_namespace_access {
    my ($self, $username, $namespace) = @_;
    return 1 unless defined $username;

    my $allowed = $self->get_allowed_namespaces($username);
    return 1 unless @$allowed;

    my %allowed_set = map { $_ => 1 } @$allowed;
    return $allowed_set{$namespace} ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::NamespaceScope - Namespace-scoped RBAC enforcement

=head1 SYNOPSIS

    my $ns_scope = Purl::API::Middleware::NamespaceScope->new(
        settings => $settings,
    );

    my $allowed = $ns_scope->get_allowed_namespaces('user1');
    # Returns: ['default', 'staging']

    $ns_scope->apply_namespace_filter('user1', \%params);
    # Injects namespace restriction into query params

=head1 DESCRIPTION

Restricts log visibility based on user's allowed namespaces.
Admin users have unrestricted access. Viewer/operator users
are limited to their configured namespaces.

Configuration in settings.json:
    {
      "auth": {
        "namespace_scope": {
          "dev1": ["default", "staging"],
          "dev2": ["production"]
        }
      }
    }

Empty array or missing entry = all namespaces (admin default).

=cut

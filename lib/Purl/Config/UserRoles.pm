package Purl::Config::UserRoles;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

requires qw(_config _with_lock save);

# ============================================
# User role management (RBAC)
# ============================================

my %VALID_ROLES = map { $_ => 1 } qw(admin operator viewer);

sub get_user_role {
    my ($self, $username) = @_;
    return 'viewer' unless defined $username && $username ne '';
    my $roles = $self->_config->{auth}{roles} // {};
    return $roles->{$username} // 'viewer';
}

sub set_user_role {
    my ($self, $username, $role) = @_;
    $role //= 'viewer';
    $role = 'viewer' unless exists $VALID_ROLES{$role};
    return $self->_with_lock(sub {
        $self->_config->{auth} //= {};
        $self->_config->{auth}{roles} //= {};
        $self->_config->{auth}{roles}{$username} = $role;
        return $self->save();
    });
}

sub ensure_user_roles {
    my ($self) = @_;
    return $self->_with_lock(sub {
        my $users = $self->_config->{auth}{users} // {};
        my $roles = $self->_config->{auth}{roles} // {};
        my $changed = 0;
        my @usernames = sort keys %$users;
        for my $i (0 .. $#usernames) {
            my $u = $usernames[$i];
            unless (exists $roles->{$u}) {
                $roles->{$u} = ($i == 0 || $u eq 'admin') ? 'admin' : 'viewer';
                $changed = 1;
            }
        }
        if ($changed) {
            $self->_config->{auth}{roles} = $roles;
            $self->save();
        }
        return $roles;
    });
}

1;

__END__

=head1 NAME

Purl::Config::UserRoles - per-user RBAC role storage (admin / operator /
viewer) in the auth section of Purl::Config.

=cut

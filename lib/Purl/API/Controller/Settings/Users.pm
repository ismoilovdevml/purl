package Purl::API::Controller::Settings::Users;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Settings manager (Purl::Config instance)
has 'settings' => (
    is       => 'ro',
    required => 1,
);

# Auth middleware for user management
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# ============================================
# User Management
# ============================================

sub list_users {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $users = $self->settings->_config->{auth}{users} // {};

        my @user_list = map {
            my $entry = $users->{$_};
            my $role = ref $entry eq 'HASH' ? ($entry->{role} // 'viewer') : 'admin';
            { username => $_, role => $role }
        } sort keys %$users;

        $c->render(json => { users => \@user_list });
    });
}

sub create_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{username} && $body->{password}) {
            $self->render_error($c, 'Username and password required', 400);
            return;
        }

        my $username = $body->{username};
        my $password = $body->{password};

        unless ($username =~ /^[a-zA-Z0-9_-]{2,32}$/) {
            $self->render_error($c, 'Username must be 2-32 alphanumeric characters', 400);
            return;
        }

        unless (length($password) >= 8) {
            $self->render_error($c, 'Password must be at least 8 characters', 400);
            return;
        }

        my $role = $body->{role} // 'viewer';
        unless ($role =~ /^(viewer|operator|admin)$/) {
            $role = 'viewer';
        }

        # Access file config directly to avoid ENV pollution
        $self->settings->_config->{auth} //= {};
        my $users = $self->settings->_config->{auth}{users} //= {};

        if (exists $users->{$username}) {
            $self->render_error($c, 'User already exists', 409);
            return;
        }

        # Hash password
        my $hashed = $self->auth_middleware->hash_password($password);
        unless ($hashed) {
            $self->render_error($c, 'Failed to hash password', 500);
            return;
        }
        $users->{$username} = { password => $hashed, role => $role };

        if ($self->settings->save()) {
            $c->render(json => { status => 'ok', username => $username });
        } else {
            # Rollback in-memory state on save failure
            delete $users->{$username};
            my $err = $self->settings->{_last_save_error} // 'unknown';
            $self->render_error($c, "Failed to create user: $err", 500);
        }
    });
}

sub update_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $username = $c->param('username');

        unless ($username && length($username) > 0) {
            $self->render_error($c, 'Username required', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };

        unless ($body && ($body->{password} || $body->{role})) {
            $self->render_error($c, 'Password or role required', 400);
            return;
        }

        $self->settings->_config->{auth} //= {};
        my $users = $self->settings->_config->{auth}{users} //= {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'User not found', 404);
            return;
        }

        my $entry = $users->{$username};
        my $current_hash = ref $entry eq 'HASH' ? $entry->{password} : $entry;
        my $current_role = ref $entry eq 'HASH' ? ($entry->{role} // 'viewer') : 'admin';

        my $new_hash = $current_hash;
        if ($body->{password} && length($body->{password}) > 0) {
            unless (length($body->{password}) >= 8) {
                $self->render_error($c, 'Password must be at least 8 characters', 400);
                return;
            }
            $new_hash = $self->auth_middleware->hash_password($body->{password});
            unless ($new_hash) {
                $self->render_error($c, 'Failed to hash password', 500);
                return;
            }
        }

        my $new_role = $body->{role} // $current_role;
        unless ($new_role =~ /^(viewer|operator|admin)$/) {
            $new_role = $current_role;
        }

        my $old_entry = $users->{$username};
        $users->{$username} = { password => $new_hash, role => $new_role };

        if ($self->settings->save()) {
            $c->render(json => { status => 'ok', message => 'User updated' });
        } else {
            # Rollback in-memory state on save failure
            $users->{$username} = $old_entry;
            my $err = $self->settings->{_last_save_error} // 'unknown';
            $self->render_error($c, "Failed to update user: $err", 500);
        }
    });
}

sub delete_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $username = $c->param('username');

        $self->settings->_config->{auth} //= {};
        my $users = $self->settings->_config->{auth}{users} //= {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'User not found', 404);
            return;
        }

        # Prevent deleting the last user
        if (scalar(keys %$users) <= 1) {
            $self->render_error($c, 'Cannot delete the last user', 400);
            return;
        }

        # Prevent deleting yourself
        my $current = $c->stash('current_user') // '';
        if ($current eq $username) {
            $self->render_error($c, 'Cannot delete your own account', 400);
            return;
        }

        my $old_entry = delete $users->{$username};

        if ($self->settings->save()) {
            $c->render(json => { status => 'ok' });
        } else {
            # Rollback in-memory state on save failure
            $users->{$username} = $old_entry;
            my $err = $self->settings->{_last_save_error} // 'unknown';
            $self->render_error($c, "Failed to delete user: $err", 500);
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::Users - dashboard user management

=cut

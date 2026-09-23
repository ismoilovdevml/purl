package Purl::API::Controller::Settings::Users;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);
use Purl::Util::Session qw(mark_revoked);

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

        # Hash BEFORE taking the settings lock: bcrypt is slow, and the write
        # below must not hold the lock for it.
        my $hashed = $self->auth_middleware->hash_password($password);
        unless ($hashed) {
            $self->render_error($c, 'Failed to hash password', 500);
            return;
        }

        my ($status, $error) = $self->_update_users(sub {
            my ($users) = @_;
            return (409, 'User already exists') if exists $users->{$username};
            $users->{$username} = { password => $hashed, role => $role };
            return;
        });
        return $self->_render_failure($c, 'create user', $status, $error) if $status;

        $c->audit_event(action => 'create_user', resource_type => 'user',
            resource_id => $username, details => "role=$role");

        $c->render(json => { status => 'ok', username => $username });
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

        my $new_hash;
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

        my $requested_role = $body->{role};
        $requested_role = undef
            if defined $requested_role && $requested_role !~ /^(viewer|operator|admin)$/;

        my ($status, $error) = $self->_update_users(sub {
            my ($users, $section) = @_;
            return (404, 'User not found') unless exists $users->{$username};

            my $entry        = $users->{$username};
            my $current_hash = ref $entry eq 'HASH' ? $entry->{password} : $entry;
            my $current_role = ref $entry eq 'HASH' ? ($entry->{role} // 'viewer') : 'admin';
            my $hash = $new_hash // $current_hash;
            my $role = $requested_role // $current_role;

            $users->{$username} = { password => $hash, role => $role };

            # A new password or a changed role must not leave sessions that
            # were issued under the old ones (#91) — including a demoted
            # admin's cookie that still says role=admin. Same locked write,
            # so the user record and the stamp are never saved apart.
            mark_revoked($section, $username)
                if $hash ne ($current_hash // '') || $role ne $current_role;
            return;
        });
        return $self->_render_failure($c, 'update user', $status, $error) if $status;

        $c->audit_event(action => 'update_user', resource_type => 'user', resource_id => $username,
            details => join(' ', ($new_hash ? 'password' : ()), ($requested_role ? "role=$requested_role" : ())));

        $c->render(json => { status => 'ok', message => 'User updated' });
    });
}

sub delete_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $username = $c->param('username');

        # Prevent deleting yourself
        my $current = $c->stash('current_user') // '';
        my $self_delete = $current eq $username;

        my ($status, $error) = $self->_update_users(sub {
            my ($users, $section) = @_;
            return (404, 'User not found') unless exists $users->{$username};
            return (400, 'Cannot delete the last user') if keys %$users <= 1;
            return (400, 'Cannot delete your own account') if $self_delete;

            delete $users->{$username};
            # The record is gone, which already refuses its local sessions; the
            # stamp also covers a same-name account created later (#91).
            mark_revoked($section, $username);
            return;
        });
        return $self->_render_failure($c, 'delete user', $status, $error) if $status;

        $c->audit_event(action => 'delete_user', resource_type => 'user', resource_id => $username);

        $c->render(json => { status => 'ok' });
    });
}

# One locked read-modify-write of auth.users (Purl::Config::update_section).
#
# These handlers used to edit settings->_config in place and save() without
# the lock, with a bcrypt hash between read and write — so a revocation stamp
# another worker wrote in between (a logout) was overwritten by the stale
# snapshot and the logged-out cookie came back. The callback runs on the
# freshly re-read section under the lock; it returns (status, message) to
# refuse (nothing is written) or nothing to save.
#
# Returns () on success, or (status, message) on refusal or save failure.
sub _update_users {
    my ($self, $cb) = @_;
    my @refused;
    my $saved = $self->settings->update_section('auth', sub {
        my ($section, $cancel) = @_;
        $section->{users} = {} unless ref $section->{users} eq 'HASH';
        @refused = $cb->($section->{users}, $section);
        $cancel->() if @refused;
        return;
    });
    return @refused if @refused;
    return if $saved;
    return (500, $self->settings->{_last_save_error} // 'unknown');
}

sub _render_failure {
    my ($self, $c, $what, $status, $error) = @_;
    $error = "Failed to $what: $error" if $status == 500;
    $self->render_error($c, $error, $status);
    return;
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::Users - dashboard user management

=cut

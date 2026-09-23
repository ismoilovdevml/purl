package Purl::API::Controller::Password;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::Session qw(
    start_session session_is_valid mark_revoked session_max_age auth_section
);
use Purl::Util::Principal qw(principal_via principal_user);
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Password hashing / verification (Purl::API::Middleware::Auth)
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# A signed-in user changes their own password. Every other session of that
# user is revoked with the old password; this one is re-issued.
sub change_password {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # Only a signed-in person changes their own password: a key or basic
        # client that also sends a cookie gets no identity from that cookie.
        my $username = principal_via($c) eq 'session' ? principal_user($c) : undef;

        unless (defined $username && length $username) {
            $self->render_error($c, 'Authentication required', 401);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{current_password} && $body->{new_password}) {
            $self->render_error($c, 'current_password and new_password required', 400);
            return;
        }

        my $current_password = $body->{current_password};
        my $new_password     = $body->{new_password};

        # Validate new password length
        unless (length($new_password) >= 8) {
            $self->render_error($c, 'New password must be at least 8 characters', 400);
            return;
        }

        # Ensure new password differs from current
        if ($current_password eq $new_password) {
            $self->render_error($c, 'New password must be different from current password', 400);
            return;
        }

        # Verify current password
        my $auth_config = $self->settings ? $self->settings->get_section('auth') : {};
        $auth_config //= {};
        my $users = $auth_config->{users} // {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'User not found', 404);
            return;
        }

        my $entry = $users->{$username};
        my $stored = ref $entry eq 'HASH' ? $entry->{password} : $entry;
        my $role = ref $entry eq 'HASH' ? ($entry->{role} // 'viewer') : 'admin';

        unless ($self->auth_middleware) {
            $self->render_error($c, 'Authentication not configured', 500);
            return;
        }

        my ($valid) = $self->auth_middleware->verify_password($current_password, $stored);

        unless ($valid) {
            $c->audit_event(action => 'change_password', status => 'failure');
            $self->render_error($c, 'Current password is incorrect', 401);
            return;
        }

        # Hash first (slow), then one locked write that stores the password
        # AND the revocation stamp: every other session of this user dies with
        # the old password, and the two can never be saved apart. The role is
        # re-read under the lock so a concurrent role change is not undone.
        my $new_hash = $self->auth_middleware->hash_password($new_password);
        unless ($new_hash) {
            $self->render_error($c, 'Failed to hash password', 500);
            return;
        }
        #
        # The current password was verified against a snapshot, and bcrypt
        # takes long enough for an admin reset to land in between. So the write
        # goes ahead only if, under the lock, the stored hash is still the one
        # that was verified AND this session was not revoked meanwhile —
        # otherwise the reset would be silently undone and the caller walk
        # away with a fresh session on a password the admin just took away.
        my $iat     = $c->session->{iat};
        my %session = %{ $c->session };
        my $max_age = session_max_age($self->settings);
        my $refused = '';
        my $saved = $self->settings->update_section('auth', sub {
            my ($section, $cancel) = @_;
            my $cur = ref $section->{users} eq 'HASH' ? $section->{users}{$username} : undef;
            my $cur_hash = ref $cur eq 'HASH' ? $cur->{password} : $cur;
            $refused = !defined $cur                          ? 'gone'
                     : ($cur_hash // '') ne ($stored // '')   ? 'changed'
                     : !session_is_valid(\%session, $section, $max_age) ? 'revoked'
                     :                                          '';
            return $cancel->() if $refused;
            $role = ref $cur eq 'HASH' ? ($cur->{role} // 'viewer') : 'admin';
            $section->{users}{$username} = { password => $new_hash, role => $role };
            mark_revoked($section, $username, $iat);
            return;
        });
        unless ($saved) {
            my %why = (
                gone    => [404, 'User not found', 'user no longer exists'],
                changed => [409, 'Your password was changed elsewhere; sign in again',
                            'password changed concurrently'],
                revoked => [409, 'Your session was revoked; sign in again',
                            'session revoked concurrently'],
            );
            my ($status, $msg, $why) = @{ $why{$refused}
                // [500, 'Failed to change password',
                      $self->settings->{_last_save_error} // 'settings not saved'] };
            $c->app->log->error("change_password for '$username' not saved: $why");
            $c->audit_event(action => 'change_password', status => 'failure', details => $why);
            $self->render_error($c, $msg, $status);
            return;
        }

        # This session is re-issued after the revocation stamp so the caller
        # stays in.
        my $auth_method = $c->session->{auth_method} // 'local';
        start_session($c, auth_section($self->settings),
            username         => $username,
            auth_method      => $auth_method,
            role             => $role,
            password_changed => 1,
        );

        $c->audit_event(action => 'change_password', status => 'success');
        $c->render(json => {
            status  => 'ok',
            message => 'Password changed successfully',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Password - a signed-in user changes their own password

=head1 DESCRIPTION

C<POST /api/auth/change-password>. Administrators resetting someone else's
password use L<Purl::API::Controller::Settings::Users>.

=cut

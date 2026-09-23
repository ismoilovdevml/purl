package Purl::API::Middleware::Auth::LoginLockout;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Per-Username Login Rate Limiting
# ============================================
#
# Failed logins per username, counted on the shared counter_store (see
# Purl::API::Middleware::Auth::RateLimit) so the lockout holds across every
# prefork worker and replica.

my $USERNAME_RATE_LIMIT_MAX    = 5;
my $USERNAME_RATE_LIMIT_WINDOW = 600;

sub _login_key {
    my ($self, $username) = @_;
    return "login:$username";
}

sub check_username_rate_limit {
    my ($self, $username) = @_;
    return 1 unless defined $username && length($username);
    # Read-only: how many failures have accrued in the current fixed window.
    my $count = $self->counter_store->get($self->_login_key($username));
    return $count < $USERNAME_RATE_LIMIT_MAX;
}

sub record_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    # Atomic increment shared across workers; TTL sets a fixed 10-min window
    # that starts at the first failure (EXPIRE applied only on the 1st incr).
    $self->counter_store->incr($self->_login_key($username), $USERNAME_RATE_LIMIT_WINDOW);
    return;
}

sub reset_failed_login {
    my ($self, $username) = @_;
    return unless defined $username && length($username);
    $self->counter_store->del($self->_login_key($username));
    return;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth::LoginLockout - per-username failed-login lockout
for Purl::API::Middleware::Auth

=head1 DESCRIPTION

Relies on the consuming class for C<counter_store>.

=cut

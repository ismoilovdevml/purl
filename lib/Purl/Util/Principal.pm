package Purl::Util::Principal;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);

our @EXPORT_OK = qw(
    set_principal clear_principal principal principal_role principal_user
    principal_via
);

# ============================================
# Who is making this request, as decided by the ONE auth step that succeeded.
#
# Before this, handlers asked the session cookie directly (session('role'),
# session('username')). check_auth accepts an API key, bearer token or basic
# auth BEFORE it looks at the session, so a request carrying a key plus a
# revoked (or pre-#91) admin cookie was authenticated by the key and then
# authorised as admin by the cookie nobody had validated.
#
# Now each auth step records its principal in the stash and every authorisation
# decision reads it from here:
#
#   via       session | api_key | bearer | basic | open
#   username  set for session and basic; undef for key/bearer/open
#   role      session: the validated session's role; everything else: viewer
#             (what require_role always gave a caller with no session)
#
# No principal => nobody: role viewer, no username.
# ============================================

my $KEY = 'purl.principal';

sub set_principal {
    my ($c, %p) = @_;
    $p{role} //= 'viewer';
    $c->stash($KEY => \%p);
    return \%p;
}

sub clear_principal {
    my ($c) = @_;
    my $stash = $c->stash;
    delete $stash->{$KEY} if ref $stash eq 'HASH';
    return;
}

sub principal {
    my ($c) = @_;
    my $p = $c->stash($KEY);
    return ref $p eq 'HASH' ? $p : {};
}

sub principal_role { my ($c) = @_; return principal($c)->{role} // 'viewer' }
sub principal_user { my ($c) = @_; return principal($c)->{username} }
sub principal_via  { my ($c) = @_; return principal($c)->{via} // '' }

1;

__END__

=head1 NAME

Purl::Util::Principal - the authenticated identity of the current request

=head1 FUNCTIONS

=over 4

=item * set_principal($c, via => ..., username => ..., role => ...) - record
who authenticated this request (role defaults to C<viewer>).

=item * clear_principal($c) - forget it (logout, rejected session).

=item * principal($c) - the principal hashref, or C<{}>.

=item * principal_role($c), principal_user($c), principal_via($c) - accessors;
role defaults to C<viewer>, via to the empty string.

=back

=cut

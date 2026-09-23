package Purl::Util::Session;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);
use Scalar::Util qw(looks_like_number);
use Time::HiRes ();
use Purl::Util::Random qw(random_hex);

our @EXPORT_OK = qw(
    start_session session_is_valid check_session end_session
    revoke_sessions session_max_age
);

# ============================================
# Dashboard session lifecycle: issue, validate, revoke.
#
# Sessions are signed Mojolicious cookies — stateless, so a copy of a cookie
# taken before logout used to keep working forever (#91): logout only asked
# the browser to drop it, and every response re-signed a fresh sliding expiry.
#
# The fix needs revocation that EVERY prefork worker and replica sees. A
# per-worker in-memory denylist is the known-broken shape here (#18/#37/#64),
# so revocation lives in settings.json, which every Purl::Config already
# re-reads when its stat stamp moves:
#
#   auth.sessions_valid_after = { <username> => <epoch, sub-second> }
#
# A session is valid only if it carries a sid and an issued-at (iat) stamp,
# its iat is newer than the user's sessions_valid_after, and it is younger than
# the absolute max age. Logout, password change and user delete/update move
# the user's stamp to "now", which kills every cookie issued before it on every
# worker at once.
#
# Why a separate map and not a field on auth.users.<name>: several writers
# replace a user record wholesale with { password, role }, and a dropped field
# would silently resurrect every revoked session. LDAP and SAML users have no
# local record at all, and their logout must still revoke.
# ============================================

my $DEFAULT_MAX_AGE = 7 * 24 * 3600;
my $IDLE_EXPIRATION = 86_400;    # sliding idle expiry, unchanged from before

# Overridable in tests to move the clock.
sub _now { return Time::HiRes::time() }

# Absolute session lifetime in seconds: PURL_SESSION_MAX_AGE, then
# session.max_age in settings.json, then 7 days. A value that is not a
# positive number is skipped — it can never disable the limit.
sub session_max_age {
    my ($settings) = @_;
    for my $v ($ENV{PURL_SESSION_MAX_AGE},
               $settings ? eval { $settings->get('session', 'max_age') } : undef) {
        return $v + 0 if defined $v && looks_like_number($v) && $v > 0;
    }
    return $DEFAULT_MAX_AGE;
}

sub _valid_after {
    my ($auth_section, $username) = @_;
    my $map = ref $auth_section eq 'HASH' ? $auth_section->{sessions_valid_after} : undef;
    return 0 unless ref $map eq 'HASH' && defined $username;
    my $v = $map->{$username};
    return looks_like_number($v) ? $v : 0;
}

# Replace whatever is in the session with a freshly issued one. Wiping first
# means nothing from a previous identity (groups, flags) survives a login.
#
# iat is taken strictly after the user's current revocation stamp: a login on
# a replica whose clock trails the one that handled the logout must not be
# born already revoked.
sub start_session {
    my ($c, $auth_section, %attrs) = @_;

    my $floor = _valid_after($auth_section, $attrs{username});
    my $now   = _now();

    my $session = $c->session;
    %$session = ();
    $session->{$_} = $attrs{$_} for keys %attrs;
    $session->{logged_in} = 1;
    $session->{sid}       = random_hex(16);    # 128 bits
    $session->{iat}       = $now > $floor ? $now : $floor + 0.001;
    $c->session(expiration => $IDLE_EXPIRATION);
    return $session;
}

sub session_is_valid {
    my ($session, $auth_section, $max_age) = @_;
    return 0 unless ref $session eq 'HASH';

    my $username = $session->{username};
    return 0 unless $session->{logged_in} && defined $username && length $username;

    # Cookies minted before #91 carry neither; they are not revocable, so they
    # are not accepted.
    return 0 unless defined $session->{sid} && length $session->{sid};
    my $iat = $session->{iat};
    return 0 unless looks_like_number($iat);

    return 0 if _now() - $iat > $max_age;
    return 0 if $iat <= _valid_after($auth_section, $username);

    # A local account that no longer exists has no business holding a session.
    my $method = $session->{auth_method} // 'local';
    if ($method eq 'local') {
        my $users = ref $auth_section eq 'HASH' ? $auth_section->{users} : undef;
        return 0 unless ref $users eq 'HASH' && exists $users->{$username};
    }

    return 1;
}

# Log the request out locally: clear the session for the rest of this request
# (later readers of session('role') see nothing) and tell the browser to drop
# the cookie.
sub end_session {
    my ($c) = @_;
    my $session = $c->session;
    %$session = ();
    $c->session(expires => 1);
    return;
}

# Validate the request's session; a present-but-invalid one is ended so the
# stale cookie is not re-signed back to the browser. Returns 1/0.
sub check_session {
    my ($c, $auth_section, $max_age) = @_;
    my $session = $c->session;
    return 0 unless $session->{logged_in} || $session->{username};
    return 1 if session_is_valid($session, $auth_section, $max_age);
    end_session($c);
    return 0;
}

# Kill every session of $username issued up to now, on every worker/replica.
# $at_least (optional) is the iat of the session asking for it: a cookie minted
# by a replica whose clock runs ahead of this one would otherwise outlive its
# own logout. Returns the settings save result.
sub revoke_sessions {
    my ($settings, $username, $at_least) = @_;
    return 0 unless $settings && defined $username && length $username;
    my $stamp = _now();
    $stamp = $at_least if looks_like_number($at_least) && $at_least > $stamp;
    return $settings->update_section('auth', sub {
        my ($section) = @_;
        $section->{sessions_valid_after} = {}
            unless ref $section->{sessions_valid_after} eq 'HASH';
        $section->{sessions_valid_after}{$username} = $stamp;
        return;
    });
}

1;

__END__

=head1 NAME

Purl::Util::Session - issue, validate and revoke dashboard sessions

=head1 FUNCTIONS

=over 4

=item * start_session($c, $auth_section, %attrs) - wipe the session and issue a
new one (C<sid>, C<iat>, C<logged_in>, 24h sliding expiry) carrying C<%attrs>
(C<username>, C<role>, C<auth_method>, ...).

=item * session_is_valid($session, $auth_section, $max_age) - true when the
session has a C<sid> and C<iat>, is younger than C<$max_age>, was issued after
the user's C<auth.sessions_valid_after> stamp and, for local accounts, the user
still exists.

=item * check_session($c, $auth_section, $max_age) - C<session_is_valid> on the
request's session; ends an invalid one.

=item * end_session($c) - clear the session and expire the cookie.

=item * revoke_sessions($settings, $username, $at_least) - set the user's
C<sessions_valid_after> to now (or C<$at_least> if later) in settings.json
(seen by every worker).

=item * session_max_age($settings) - C<PURL_SESSION_MAX_AGE>, then
C<session.max_age>, then 7 days (seconds).

=back

=cut

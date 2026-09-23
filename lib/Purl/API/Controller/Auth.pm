package Purl::API::Controller::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::Session qw(
    start_session check_session end_session revoke_sessions session_max_age
    auth_section
);
use Purl::Util::Principal qw(principal_user);
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Auth middleware for password verification
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# LDAP middleware for LDAP/AD auth
has 'ldap_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# Settings for user lookup
has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

# CSRF tokens are owned by the single implementation in
# Purl::API::Middleware::Auth (one HMAC secret shared for issue + verify).
# This endpoint simply hands the caller a token signed with that secret.
sub csrf_token {
    my ($self, $c) = @_;
    my $mw = $self->auth_middleware;
    unless ($mw) {
        $self->render_error($c, 'CSRF is not available', 500);
        return;
    }
    $c->render(json => { csrf_token => $mw->generate_csrf_token() });
}

# ============================================
# Session-based Authentication
# ============================================

sub login {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{username} && $body->{password}) {
            $self->render_error($c, 'Username and password required', 400);
            return;
        }

        my $username = $body->{username};
        my $password = $body->{password};

        my $auth_mw = $self->auth_middleware;

        # ── Brute-force lockout (per-username, 5 failures / 10 min) ──
        # Checked BEFORE any credential verification so a locked account cannot
        # be probed, and applies regardless of auth backend (local/LDAP). The
        # message is deliberately generic — it must NOT reveal whether the
        # username exists.
        if ($auth_mw && !$auth_mw->check_username_rate_limit($username)) {
            $c->audit_event(action => 'login', status => 'failure', actor => $username);
            $self->render_error($c,
                'Too many failed login attempts. Please try again later.', 429);
            return;
        }

        # ── LDAP/AD authentication path ──
        my $ldap_mw = $self->ldap_middleware;
        if ($ldap_mw) {
            my $result = eval { $ldap_mw->authenticate($username, $password) };
            if ($@) {
                # Unexpected error — fall through to local auth
                $c->app->log->warn("LDAP authenticate error: $@");
            } elsif ($result->{unavailable}) {
                # LDAP server down — fall through to local auth
                $c->app->log->warn("LDAP unavailable, falling back to local auth for: $username");
            } elsif ($result->{success}) {
                # LDAP login successful
                my @ldap_groups = @{ $result->{groups} // [] };

                # Detect admin role from LDAP groups
                my $ldap_cfg = $self->ldap_middleware->config // {};
                my $admin_group = $ldap_cfg->{admin_group} // 'admins';
                my $is_admin = grep { lc($_) eq lc($admin_group) } @ldap_groups;

                start_session($c, auth_section($self->settings),
                    username    => $username,
                    auth_method => 'ldap',
                    ldap_groups => \@ldap_groups,
                    role        => $is_admin ? 'admin' : 'viewer',
                    ($is_admin ? (is_admin => 1) : ()),
                );

                $auth_mw->reset_failed_login($username) if $auth_mw;
                $c->audit_event(action => 'login', status => 'success');
                $c->render(json => {
                    authenticated => 1,
                    username      => $username,
                    auth_method   => 'ldap',
                    role          => $c->session->{role},
                });
                return;
            } else {
                # LDAP explicitly rejected credentials — do not fall through
                $auth_mw->record_failed_login($username) if $auth_mw;
                $c->audit_event(action => 'login', status => 'failure', actor => $username);
                $self->render_error($c, 'Invalid username or password', 401);
                return;
            }
        }

        # ── Local authentication path ──
        my $auth_config = $self->settings ? $self->settings->get_section('auth') : {};
        $auth_config //= {};
        my $users = $auth_config->{users} // {};

        unless (exists $users->{$username}) {
            $auth_mw->record_failed_login($username) if $auth_mw;
            $c->audit_event(action => 'login', status => 'failure', actor => $username);
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        my $entry = $users->{$username};
        my $stored = ref $entry eq 'HASH' ? $entry->{password} : $entry;
        my $user_role = ref $entry eq 'HASH' ? ($entry->{role} // 'viewer') : 'admin';
        my $valid = 0;

        my $new_hash;
        if ($self->auth_middleware && $stored && ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/)) {
            ($valid, $new_hash) = $self->auth_middleware->verify_password($password, $stored);
        } elsif ($stored) {
            $valid = ($stored eq $password);
            # Migrate plaintext to bcrypt
            if ($valid && $self->auth_middleware) {
                $new_hash = $self->auth_middleware->hash_password($password);
            }
        }

        unless ($valid) {
            $auth_mw->record_failed_login($username) if $auth_mw;
            $c->audit_event(action => 'login', status => 'failure', actor => $username);
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        # Credentials verified — clear any accrued lockout counter for this user.
        $auth_mw->reset_failed_login($username) if $auth_mw;

        # Migrate legacy hash to bcrypt on successful login
        if ($new_hash && $self->settings) {
            # update_section, not get_section/set_section: the hand-written
            # sequence re-reads outside any lock, so a user created by another
            # worker in between is silently dropped by this save.
            $self->settings->update_section('auth', sub {
                my ($section) = @_;
                $section->{users}{$username} = { password => $new_hash, role => $user_role };
            });
            $c->app->log->info("Password hash migrated to bcrypt for user: $username");
        }

        # Check if user needs to change default password
        my $password_change_required =
            $auth_mw ? $auth_mw->password_change_required($username, $password) : 0;

        # Force password change before granting full access
        start_session($c, $auth_config,
            username    => $username,
            auth_method => 'local',
            role        => $user_role,
            ($password_change_required ? (must_change_password => 1) : ()),
        );

        $c->audit_event(action => 'login', status => 'success');
        my $response = {
            authenticated => 1,
            username      => $username,
            auth_method   => 'local',
            role          => $user_role,
        };
        $response->{password_change_required} = \1 if $password_change_required;
        $c->render(json => $response);
    });
}

sub logout {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # Server-side revocation (#91): expiring the cookie only asks the
        # browser to forget it. Moving the user's sessions_valid_after stamp
        # kills every copy of every cookie issued so far, on every worker and
        # replica — including one an in-flight request re-sets after this.
        # Only a genuinely valid session may revoke (check_session makes it the
        # principal), so a dead or forged-name cookie cannot log someone out.
        #
        # A live session's logout needs the CSRF token like any other cookie
        # write: a cross-site POST must not be able to sign the user out
        # everywhere. A dead cookie has nothing to protect, so it is dropped
        # without one.
        my $revoked = 1;
        my $username;
        if (check_session($c, auth_section($self->settings), session_max_age($self->settings))) {
            my $mw = $self->auth_middleware;
            if ($mw && !$mw->check_csrf($c)) {
                $c->render(json => { error => 'CSRF token missing or invalid', csrf => \1 },
                    status => 403);
                return;
            }
            $username = principal_user($c);
            $revoked  = revoke_sessions($self->settings, $username, $c->session->{iat});
        }
        end_session($c);    # the browser drops its copy either way

        # If the stamp could not be persisted, every copy of this cookie is
        # still valid. Saying "ok" would be a false security claim, so the
        # failure is logged, audited and answered with 500.
        unless ($revoked) {
            my $err = ($self->settings && $self->settings->{_last_save_error}) // 'unknown';
            $c->app->log->error("logout: could not revoke sessions of '$username': $err");
            $c->audit_event(action => 'logout', status => 'failure', actor => $username,
                details => 'session revocation not persisted');
            $self->render_error($c,
                'Signed out in this browser, but the session could not be revoked on the server', 500);
            return;
        }

        $c->audit_event(action => 'logout', ($username ? (actor => $username) : ()));
        $c->render(json => { status => 'ok' });
    });
}

# Does this instance require a login at all?
#
# The dashboard asks /auth/me this question instead of guessing, so an open
# instance never pops up a login form for credentials that do not exist. The
# middleware owns the ENV > file > default precedence; settings is the
# fallback when no middleware is wired (tests, embedded use).
sub _auth_required {
    my ($self) = @_;

    return $self->auth_middleware->auth_enabled ? 1 : 0 if $self->auth_middleware;
    return $self->settings && $self->settings->auth_enabled ? 1 : 0;
}

sub me {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # A signed cookie that was revoked, outlived session.max_age or predates
        # sid/iat is reported as signed out, and the browser is told to drop it.
        my $valid = check_session($c, auth_section($self->settings), session_max_age($self->settings));
        my $username = $c->session->{username};

        # JSON boolean, not 0/1: the frontend tests `data.auth_required`
        # directly and a stringified "0" would be truthy in JS.
        my $auth_required = $self->_auth_required ? \1 : \0;

        # Running inside Kubernetes? Drives the dashboard's K8s page. Public,
        # like the rest of this response: it reveals only the deployment kind.
        my $k8s_mode = $ENV{KUBERNETES_SERVICE_HOST} ? \1 : \0;

        if ($valid) {
            my $response = {
                authenticated => 1,
                auth_required => $auth_required,
                k8s_mode      => $k8s_mode,
                username      => $username,
                auth_method   => $c->session->{auth_method} // 'local',
                role          => $c->session->{role} // 'viewer',
                ldap_groups   => $c->session->{ldap_groups} // [],
                saml_groups   => $c->session->{saml_groups} // [],
            };
            $response->{must_change_password} = \1 if $c->session->{must_change_password};
            $c->render(json => $response);
        } else {
            $c->render(json => {
                authenticated => 0,
                auth_required => $auth_required,
                k8s_mode      => $k8s_mode,
            });
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Auth - Authentication controller

=head1 DESCRIPTION

Handles CSRF tokens, session-based login/logout and C</auth/me>. Password
change lives in L<Purl::API::Controller::Password>, the SAML SSO flow in
L<Purl::API::Controller::SSO>.

=cut

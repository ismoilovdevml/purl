package Purl::API::Controller::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
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

# SAML/SSO middleware for SSO auth
has 'saml_middleware' => (
    is      => 'rw',
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
                $c->session->{username}    = $username;
                $c->session->{logged_in}   = 1;
                $c->session->{auth_method} = 'ldap';
                $c->session->{ldap_groups} = \@ldap_groups;

                # Detect admin role from LDAP groups
                my $ldap_cfg = $self->ldap_middleware->config // {};
                my $admin_group = $ldap_cfg->{admin_group} // 'admins';
                if (grep { lc($_) eq lc($admin_group) } @ldap_groups) {
                    $c->session->{is_admin} = 1;
                    $c->session->{role} = 'admin';
                } else {
                    $c->session->{role} = 'viewer';
                }

                $c->session(expiration => 86400);

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
        my $password_change_required = 0;
        if ($username eq 'admin' && $password eq 'admin') {
            $password_change_required = 1;
        }

        # Force password change before granting full access
        if ($password_change_required) {
            $c->session->{must_change_password} = 1;
        }

        # Set session
        $c->session->{username}    = $username;
        $c->session->{logged_in}   = 1;
        $c->session->{auth_method} = 'local';
        $c->session->{role}        = $user_role;
        $c->session(expiration => 86400);  # 24 hours

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
        $c->audit_event(action => 'logout');
        $c->session(expires => 1);
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
        my $username = $c->session->{username};
        my $logged_in = $c->session->{logged_in};

        # JSON boolean, not 0/1: the frontend tests `data.auth_required`
        # directly and a stringified "0" would be truthy in JS.
        my $auth_required = $self->_auth_required ? \1 : \0;

        # Running inside Kubernetes? Drives the dashboard's K8s page. Public,
        # like the rest of this response: it reveals only the deployment kind.
        my $k8s_mode = $ENV{KUBERNETES_SERVICE_HOST} ? \1 : \0;

        if ($logged_in && $username) {
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

sub change_password {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->session->{username};
        my $logged_in = $c->session->{logged_in};

        unless ($logged_in && $username) {
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

        # Hash and store new password
        my $new_hash = $self->auth_middleware->hash_password($new_password);
        $self->settings->update_section('auth', sub {
            my ($section) = @_;
            $section->{users}{$username} = { password => $new_hash, role => $role };
        });

        # Clear the forced password change flag
        $c->session->{must_change_password} = 0;
        $c->session->{password_changed} = 1;

        $c->audit_event(action => 'change_password', status => 'success');
        $c->render(json => {
            status  => 'ok',
            message => 'Password changed successfully',
        });
    });
}

# SSO/SAML 2.0 — Initiate SP login redirect
sub sso_login {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw && $saml_mw->is_available()) {
            $self->render_error($c, 'SSO is not configured or unavailable', 503);
            return;
        }

        my $relay_state = $c->param('redirect') // '/';

        my $result = $saml_mw->build_authn_request($relay_state);
        unless ($result->{success}) {
            $c->app->log->warn("SSO: build_authn_request failed: $result->{error}");
            $self->render_error($c, 'Failed to initiate SSO login', 500);
            return;
        }

        $c->redirect_to($result->{redirect_url});
    });
}

# SSO/SAML 2.0 — Assertion Consumer Service (receives IdP POST)
sub sso_callback {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $self->render_error($c, 'SSO not configured', 503);
            return;
        }

        my $saml_response = $c->param('SAMLResponse');
        unless ($saml_response && length $saml_response) {
            $self->render_error($c, 'Missing SAMLResponse parameter', 400);
            return;
        }

        my $relay_state = $c->param('RelayState') // '/';

        my $result = $saml_mw->validate_response($saml_response, $relay_state);

        unless ($result->{success}) {
            $c->app->log->warn("SSO: SAML validation failed: $result->{error}");
            # Redirect to login page with error
            $c->redirect_to('/?error=sso_failed');
            return;
        }

        # Create session — same shape as LDAP session
        my @saml_groups = @{ $result->{groups} // [] };
        $c->session->{username}    = $result->{username};
        $c->session->{logged_in}   = 1;
        $c->session->{auth_method} = 'saml';
        $c->session->{saml_groups} = \@saml_groups;

        # Detect admin role from SAML groups
        my $saml_mw_cfg = $saml_mw->config // {};
        my $admin_group = $saml_mw_cfg->{admin_group} // 'admins';
        if (grep { lc($_) eq lc($admin_group) } @saml_groups) {
            $c->session->{is_admin} = 1;
            $c->session->{role} = 'admin';
        } else {
            $c->session->{role} = 'viewer';
        }

        $c->session(expiration => 86400);

        # Safe redirect — only allow relative paths
        my $safe_redirect = '/';
        if ($relay_state && $relay_state =~ m{^/[^/]}) {
            $safe_redirect = $relay_state;
        }

        $c->redirect_to($safe_redirect);
    });
}

# SSO/SAML 2.0 — SP metadata XML
sub sso_metadata {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $self->render_error($c, 'SSO not configured', 404);
            return;
        }

        my $xml = eval { $saml_mw->generate_metadata() };
        if ($@ || !$xml) {
            $self->render_error($c, 'Failed to generate SAML metadata', 500);
            return;
        }

        $c->res->headers->content_type('application/xml; charset=utf-8');
        $c->render(text => $xml);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Auth - Authentication controller

=head1 DESCRIPTION

Handles CSRF tokens, session-based login/logout, password change and SAML SSO.

=cut

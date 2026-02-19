package Purl::API::Controller::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes qw(time);
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# CSRF token secret (generated on instantiation or passed in config)
has 'csrf_secret' => (
    is      => 'ro',
    default => sub { join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..32) },
);

# Auth middleware for password verification
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# LDAP middleware for enterprise LDAP/AD auth
has 'ldap_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# SAML/SSO middleware for enterprise SSO auth
has 'saml_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

# License middleware for plan checks
has 'license_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# Settings for user lookup
has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

sub _generate_csrf_token {
    my ($self, $session_id) = @_;
    $session_id //= join('', map { ('a'..'z', 0..9)[rand 36] } 1..16);
    my $timestamp = int(time() / 3600);  # Valid for 1 hour
    my $token = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return "$session_id:$timestamp:$token";
}

sub csrf_token {
    my ($self, $c) = @_;
    my $token = $self->_generate_csrf_token();
    $c->render(json => { csrf_token => $token });
}

sub verify_csrf_token {
    my ($self, $token) = @_;
    return 0 unless $token && $token =~ /^([^:]+):(\d+):([a-f0-9]+)$/;
    my ($session_id, $timestamp, $hash) = ($1, $2, $3);
    my $current = int(time() / 3600);
    # Token valid for 2 hours
    return 0 if abs($current - $timestamp) > 2;
    my $expected = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return $hash eq $expected;
}

# ============================================
# Session-based Authentication (Pro/Enterprise)
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

        # ── LDAP/AD authentication path (Enterprise) ──
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
                $c->session->{username}    = $username;
                $c->session->{logged_in}   = 1;
                $c->session->{auth_method} = 'ldap';
                $c->session->{ldap_groups} = $result->{groups} // [];
                $c->session(expiration => 86400);

                $c->audit_event(action => 'login', status => 'success');
                $c->render(json => {
                    authenticated => 1,
                    username      => $username,
                    auth_method   => 'ldap',
                });
                return;
            } else {
                # LDAP explicitly rejected credentials — do not fall through
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
            $c->audit_event(action => 'login', status => 'failure', actor => $username);
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        my $stored = $users->{$username};
        my $valid = 0;

        my $new_hash;
        if ($self->auth_middleware && ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/)) {
            ($valid, $new_hash) = $self->auth_middleware->verify_password($password, $stored);
        } else {
            $valid = ($stored eq $password);
            # Migrate plaintext to bcrypt
            if ($valid && $self->auth_middleware) {
                $new_hash = $self->auth_middleware->hash_password($password);
            }
        }

        unless ($valid) {
            $c->audit_event(action => 'login', status => 'failure', actor => $username);
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        # Migrate legacy hash to bcrypt on successful login
        if ($new_hash && $self->settings) {
            my $section = $self->settings->get_section('auth') // {};
            $section->{users}{$username} = $new_hash;
            $self->settings->set_section('auth', $section);
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
        $c->session(expiration => 86400);  # 24 hours

        $c->audit_event(action => 'login', status => 'success');
        my $response = {
            authenticated => 1,
            username      => $username,
            auth_method   => 'local',
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

sub me {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->session->{username};
        my $logged_in = $c->session->{logged_in};

        if ($logged_in && $username) {
            my $response = {
                authenticated => 1,
                username      => $username,
                auth_method   => $c->session->{auth_method} // 'local',
                ldap_groups   => $c->session->{ldap_groups} // [],
                saml_groups   => $c->session->{saml_groups} // [],
            };
            $response->{must_change_password} = \1 if $c->session->{must_change_password};
            $c->render(json => $response);
        } else {
            $c->render(json => { authenticated => 0 });
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

        my $stored = $users->{$username};
        my ($valid) = $self->auth_middleware->verify_password($current_password, $stored);

        unless ($valid) {
            $c->audit_event(action => 'change_password', status => 'failure');
            $self->render_error($c, 'Current password is incorrect', 401);
            return;
        }

        # Hash and store new password
        my $new_hash = $self->auth_middleware->hash_password($new_password);
        my $section = $self->settings->get_section('auth') // {};
        $section->{users}{$username} = $new_hash;
        $self->settings->set_section('auth', $section);

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
        $c->session->{username}    = $result->{username};
        $c->session->{logged_in}   = 1;
        $c->session->{auth_method} = 'saml';
        $c->session->{saml_groups} = $result->{groups} // [];
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

Handles CSRF tokens and session-based authentication for Pro/Enterprise plans.

=cut

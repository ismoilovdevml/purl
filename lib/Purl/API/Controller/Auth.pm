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

                $c->render(json => {
                    authenticated => 1,
                    username      => $username,
                    auth_method   => 'ldap',
                });
                return;
            } else {
                # LDAP explicitly rejected credentials — do not fall through
                $self->render_error($c, 'Invalid username or password', 401);
                return;
            }
        }

        # ── Local authentication path ──
        my $auth_config = $self->settings ? $self->settings->get_section('auth') : {};
        $auth_config //= {};
        my $users = $auth_config->{users} // {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        my $stored = $users->{$username};
        my $valid = 0;

        if ($stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/) {
            $valid = $self->auth_middleware->verify_password($password, $stored);
        } else {
            $valid = ($stored eq $password);
        }

        unless ($valid) {
            $self->render_error($c, 'Invalid username or password', 401);
            return;
        }

        # Set session
        $c->session->{username}    = $username;
        $c->session->{logged_in}   = 1;
        $c->session->{auth_method} = 'local';
        $c->session(expiration => 86400);  # 24 hours

        $c->render(json => {
            authenticated => 1,
            username      => $username,
            auth_method   => 'local',
        });
    });
}

sub logout {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
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
            $c->render(json => {
                authenticated => 1,
                username      => $username,
                auth_method   => $c->session->{auth_method} // 'local',
                ldap_groups   => $c->session->{ldap_groups} // [],
            });
        } else {
            $c->render(json => { authenticated => 0 });
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Auth - Authentication controller

=head1 DESCRIPTION

Handles CSRF tokens and session-based authentication for Pro/Enterprise plans.

=cut

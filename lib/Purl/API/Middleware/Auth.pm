package Purl::API::Middleware::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use MIME::Base64 qw(decode_base64);
use Purl::Util::ClientIP qw(resolve_client_ip);
use Purl::Util::IngestRoutes qw(is_ingest_request);
use Purl::Util::Session qw(check_session session_is_valid session_max_age);
use Purl::Util::Principal qw(set_principal);
use namespace::clean;

# Cross-cutting concerns live in roles; this class is request authentication
# (API key / bearer / basic / session) and client identity only.
with 'Purl::API::Middleware::Auth::Password';
with 'Purl::API::Middleware::Auth::CSRF';
with 'Purl::API::Middleware::Auth::RateLimit';
with 'Purl::API::Middleware::Auth::LoginLockout';

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

# Trusted reverse-proxy list (arrayref of CIDRs/IPs). Empty => never trust XFF.
has 'trusted_proxies' => (
    is      => 'rw',
    default => sub { [] },
);

# Settings reference for user lookup
has 'settings' => (
    is      => 'rw',
    default => sub { undef },
);

# ============================================
# Authentication Check
# ============================================

# The auth section, read through the LIVE Purl::Config whenever one is wired.
#
# `config` is a plain hashref assembled before fork() from get_section(), and
# get_section returns a COPY — so a worker that only ever reads that hashref
# keeps the pre-fork snapshot forever, and an API key or user added through the
# UI is rejected by every worker except the one that wrote it. Purl::Config
# re-reads settings.json whenever its stat stamp moves, which is what actually
# carries the reload into this gate. Controller::Auth already reads this way.
sub _auth_config {
    my ($self) = @_;

    if (my $settings = $self->settings) {
        my $section = eval { $settings->get_section('auth') };
        return $section if ref $section eq 'HASH';
    }

    return $self->config->{auth} // {};
}

# Is authentication required on this instance? One resolver, so the gate below
# and the auth_required flag /auth/me reports cannot disagree.
sub auth_enabled {
    my ($self) = @_;

    return $self->settings->auth_enabled if $self->settings;

    my $section = $self->config->{auth} // {};
    return ($ENV{PURL_AUTH_ENABLED} // $section->{enabled} // 0) ? 1 : 0;
}

# Authenticate the request and record WHO it is (Purl::Util::Principal).
#
# The first credential that authenticates is the only source of identity and
# role for the rest of the request. A session cookie sent alongside an API key,
# bearer token or basic auth is not consulted at all — it adds no authority and
# is not re-signed. Before this, handlers read session('role') directly, so a
# key plus a revoked admin cookie was served as admin (#91 review).
#
# Key, bearer and basic callers get role viewer: that is what require_role
# always gave a caller without a session, and it is unchanged.
sub check_auth {
    my ($self, $c) = @_;
    my $auth_config = $self->_auth_config;

    # API Key auth always works (programmatic access)
    if ($self->_check_api_key($c, $auth_config)) {
        set_principal($c, via => 'api_key');
        return 1;
    }

    # Same key material over `Authorization: Bearer`, on ingest routes only —
    # for clients that cannot set a custom header (kube-apiserver audit webhook).
    if ($self->_check_bearer_token($c, $auth_config)) {
        set_principal($c, via => 'bearer');
        return 1;
    }

    # Basic auth always works. `defined`, not truth: "0" is a valid username.
    # The stored hash is kept on the principal so a long-lived connection (the
    # live-tail socket) can later tell that the password changed.
    my ($user, $stored, $pass) = $self->_check_basic_auth($c, $auth_config);
    if (defined $user) {
        $c->stash(current_user => 'api');
        set_principal($c, via => 'basic', username => $user, password_hash => $stored,
            must_change_password => $self->password_change_required($user, $pass));
        return 1;
    }

    # A valid session cookie. There is deliberately no Origin/Referer
    # "same-origin" bypass: those headers are attacker-controlled and must
    # never grant access.
    return 1 if $self->_check_session($c);

    # Auth disabled entirely => open instance (no credentials configured).
    unless ($self->auth_enabled) {
        set_principal($c, via => 'open');
        return 1;
    }

    return 0;
}

# Is this (already accepted) session still good? For connections that outlive
# the request that authenticated them — the live-tail WebSocket re-asks this
# periodically so a logout or password change also closes it.
sub session_still_valid {
    my ($self, $session) = @_;
    return session_is_valid($session, $self->_auth_config, session_max_age($self->settings));
}

# A signed cookie alone is not enough: it must also be unrevoked and inside
# its absolute lifetime (see Purl::Util::Session, #91). The auth section is
# read through the live Purl::Config, so a logout on any worker or replica is
# honoured here on the next request.
sub _check_session {
    my ($self, $c) = @_;
    return 0 unless check_session($c, $self->_auth_config, session_max_age($self->settings));
    $c->stash(current_user => $c->session->{username});
    return 1;
}

sub _check_api_key {
    my ($self, $c, $auth_config) = @_;

    my $api_key = $c->req->headers->header('X-API-Key');
    return 0 unless $api_key;

    return $self->_api_key_is_valid($api_key, $auth_config);
}

# Accept an ingest API key presented as `Authorization: Bearer <key>`.
#
# WHY: the kube-apiserver audit webhook (deploy/k8s-audit/) is configured with a
# kubeconfig, and a kubeconfig can present a bearer token or a client
# certificate — it cannot set an arbitrary header. Same key material, same
# validation as X-API-Key; only the transport differs.
#
# SCOPE: ingest routes only (see Purl::Util::IngestRoutes). The dashboard is
# session-cookie authenticated and must not gain a second credential transport.
#
# PRECEDENCE: X-API-Key wins outright. If that header is present it alone
# decides, so a client sending both never gets a surprising "the other one let
# me in" result, and a revoked X-API-Key cannot be rescued by a bearer token.
sub _check_bearer_token {
    my ($self, $c, $auth_config) = @_;

    return 0 if defined $c->req->headers->header('X-API-Key');

    my $header = $c->req->headers->authorization;
    return 0 unless defined $header;

    # RFC 7235: the auth-scheme token is case-insensitive; the credential that
    # follows is not. Exactly one SP separates them and an API key contains no
    # whitespace, so "Bearer  k" (two spaces) and "Bearer k extra" are
    # malformed rather than keys with odd characters.
    return 0 unless $header =~ /\ABearer (\S+)\z/i;
    my $key = $1;

    return 0 unless is_ingest_request($c->req->method, $c->req->url->path->to_string);

    return $self->_api_key_is_valid($key, $auth_config);
}

# Validate raw key material against the configured ingest keys, whatever header
# carried it. Supports both plain strings and hash entries.
#
# The list may also arrive as the raw comma-separated PURL_API_KEYS string:
# get_section() resolves ENV over file, so reading through Purl::Config hands
# back whatever the env var contains. Treating that string as an arrayref is a
# 500 on every authenticated request.
sub _api_key_is_valid {
    my ($self, $key, $auth_config) = @_;

    return 0 unless defined $key && length $key;

    # ENV API keys (comma-separated)
    if (my $env_keys = $ENV{PURL_API_KEYS}) {
        my @keys = split /,/, $env_keys;
        return 1 if grep { $_ eq $key } @keys;
    }

    my $valid_keys = $auth_config->{api_keys} // [];
    $valid_keys = [ split /,/, $valid_keys ] unless ref $valid_keys eq 'ARRAY';
    for my $entry (@$valid_keys) {
        my $stored = ref $entry eq 'HASH' ? ($entry->{key} // '') : $entry;
        next unless defined $stored;
        return 1 if $stored eq $key;
    }

    return 0;
}

sub _check_basic_auth {
    my ($self, $c, $auth_config) = @_;

    my $auth_header = $c->req->headers->authorization // '';
    return unless $auth_header =~ /^Basic\s+(.+)$/;

    my $decoded = decode_base64($1);
    my ($user, $pass) = split /:/, $decoded, 2;
    return unless defined $user && defined $pass;

    my $stored = $self->_stored_password_hash($auth_config, $user);
    return unless defined $stored && length $stored;

    # Bcrypt or legacy SHA256 hash
    my $valid;
    if ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/) {
        # Auto-migrate hash if needed (basic auth won't save, but login will)
        ($valid) = $self->verify_password($pass, $stored);
    } else {
        $valid = $stored eq $pass;    # legacy plaintext
    }
    return $valid ? ($user, $stored, $pass) : ();
}

# The stored password (hash) of a local user, or undef when there is none.
sub _stored_password_hash {
    my ($self, $auth_config, $user) = @_;
    my $users = ref $auth_config->{users} eq 'HASH' ? $auth_config->{users} : {};
    return unless defined $user && exists $users->{$user};
    my $entry = $users->{$user};
    return ref $entry eq 'HASH' ? $entry->{password} : $entry;
}

# Is a Basic credential accepted at a connection's start still good? The user
# must still exist with the very password hash that was verified then — a
# password change, reset or deletion ends it. For long-lived connections
# (live tail), which check_auth saw only once.
sub basic_still_valid {
    my ($self, $username, $stored) = @_;
    return 0 unless defined $stored;
    my $now = $self->_stored_password_hash($self->_auth_config, $username);
    return defined $now && $now eq $stored ? 1 : 0;
}

# ============================================
# API Key Reload
# ============================================

sub reload_api_keys {
    my ($self) = @_;
    return unless $self->settings;
    my $auth_section = $self->settings->get_section('auth') // {};
    $self->config->{auth}{api_keys} = $auth_section->{api_keys} // [];
    return 1;
}

# Resolve the real client IP, honouring X-Forwarded-For only when the socket
# peer is a configured trusted proxy. See Purl::Util::ClientIP.
sub client_ip {
    my ($self, $c) = @_;
    my $peer = $c->tx->remote_address // '127.0.0.1';
    my $trusted = $self->trusted_proxies;
    return $peer unless $trusted && @$trusted;
    return resolve_client_ip(
        peer            => $peer,
        forwarded_for   => $c->req->headers->header('X-Forwarded-For'),
        trusted_proxies => $trusted,
    );
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth - Authentication, CSRF, and Rate Limiting

=head1 SYNOPSIS

    use Purl::API::Middleware::Auth;

    my $auth = Purl::API::Middleware::Auth->new(
        config         => $config,
        rate_limit_max => 1000,
    );

    # Check authentication
    if ($auth->check_auth($c)) {
        # Authenticated
    }

    # Generate CSRF token
    my $token = $auth->generate_csrf_token();

    # Verify CSRF token
    if ($auth->verify_csrf_token($token)) {
        # Valid
    }

    # Rate limiting
    if ($auth->check_rate_limit($ip)) {
        # Within limits
    }

    # Hash password
    my $hash = $auth->hash_password('secret123');

=head1 COMPOSITION

Password hashing, CSRF, rate limiting and login lockout are composed in from
L<Purl::API::Middleware::Auth::Password>, L<Purl::API::Middleware::Auth::CSRF>,
L<Purl::API::Middleware::Auth::RateLimit> and
L<Purl::API::Middleware::Auth::LoginLockout>; the methods below are all
callable on this class.

=head1 METHODS

=head2 Authentication

=over 4

=item * check_auth($c) - Check if request is authenticated. Credentials, in the
order they are consulted: C<X-API-Key>; C<Authorization: Bearer E<lt>api keyE<gt>>
(ingest routes only — see L<Purl::Util::IngestRoutes>); C<Authorization: Basic>;
session cookie. C<X-API-Key> takes precedence: when that header is present the
bearer token is ignored entirely. The credential that succeeds becomes the
request principal (L<Purl::Util::Principal>); a session cookie sent alongside a
key, bearer token or basic auth is ignored.

=item * session_still_valid($session) - re-check an accepted session against
the live revocation stamps and max age (long-lived connections).

=item * hash_password($password, $salt) - Hash a password

=item * verify_password($password, $stored) - Verify password hash

=back

=head2 CSRF Protection

=over 4

=item * generate_csrf_token($session_id) - Generate new CSRF token

=item * verify_csrf_token($token) - Verify CSRF token validity

=item * check_csrf($c) - Check if CSRF token is required and valid

=back

=head2 Rate Limiting

=over 4

=item * check_rate_limit($ip) - Check if IP is within rate limits

=item * get_rate_limit_remaining($ip) - Get remaining requests for IP

=back

=cut

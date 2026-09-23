#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Auth;
use Purl::API::Controller::SSO;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn { }
    sub info { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if @_ > 2; $_[0]->{h}{$_[1]} }
    sub content_type { $_[0]->{h}{'Content-Type'} = $_[1] if @_ > 1 }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReq;
    sub new { bless { body => $_[1] // '' }, $_[0] }
    sub body { $_[0]->{body} }

    package MockAuthCtrl;
    sub new {
        my ($class, %opts) = @_;
        bless {
            req         => MockReq->new($opts{body}),
            res         => MockRes->new,
            rendered    => undef,
            redirected  => undef,
            stash       => $opts{stash} // {},
            session     => $opts{session} // {},
            params      => $opts{params} // {},
            app         => MockApp->new,
            audit_calls => [],
        }, $class;
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{$_[1]} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub redirect_to { $_[0]->{redirected} = $_[1] }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, @args) = @_;
        return $self->{session} unless @args;
        if (@args == 1) {
            return $self->{session}{$args[0]};
        }
        # session(key => value) pair mode is not standard but used for expiration
        $self->{session}{$args[0]} = $args[1] if @args == 2;
    }
    sub audit_event { push @{$_[0]->{audit_calls}}, { @_[1..$#_] } }

    package MockAuthMiddleware;
    sub new { bless { fails => {} }, $_[0] }
    sub verify_password {
        my ($self, $pass, $stored) = @_;
        # Simple mock: returns (valid, new_hash) like bcrypt version
        return $pass eq 'correctpassword' ? (1, undef) : (0, undef);
    }
    sub hash_password { '$2b$12$' . ('a' x 53) }
    # Mirrors the real middleware's single default-password rule.
    sub password_change_required { ($_[1] // '') eq 'admin' && ($_[2] // '') eq 'admin' ? 1 : 0 }
    # Mirrors the real middleware: one resolver for "is auth on".
    sub auth_enabled { $_[0]->{auth_enabled} ? 1 : 0 }
    # Per-username lockout stubs mirroring the real middleware contract:
    # 5 failures per window, reset clears, undef/empty are no-ops.
    sub check_username_rate_limit {
        my ($self, $u) = @_;
        return 1 unless defined $u && length $u;
        return ($self->{fails}{$u} // 0) < 5 ? 1 : 0;
    }
    sub record_failed_login {
        my ($self, $u) = @_;
        return unless defined $u && length $u;
        $self->{fails}{$u}++;
        return;
    }
    sub reset_failed_login {
        my ($self, $u) = @_;
        return unless defined $u && length $u;
        delete $self->{fails}{$u};
        return;
    }

    package MockSettings;
    sub new { bless { sections => $_[1] // {} }, $_[0] }
    sub get_section { $_[0]->{sections}{$_[1]} // {} }
    sub set_section { $_[0]->{sections}{$_[1]} = $_[2] }
    # Locked read-modify-write; the real one re-reads settings.json inside the
    # lock so a concurrent worker's change is not lost.
    sub update_section {
        my ($self, $section, $cb) = @_;
        my $data = $self->get_section($section);
        $cb->($data);
        $self->{sections}{$section} = $data;
        return 1;
    }
    sub auth_enabled { $_[0]->{sections}{auth}{enabled} ? 1 : 0 }

    package MockStorage;
    sub new { bless {}, $_[0] }
}

# ============================================
# csrf_token — now delegates to the single CSRF implementation in the
# auth middleware (one shared HMAC secret for issue + verify).
# ============================================
subtest 'csrf_token returns token signed by the middleware' => sub {
    require Purl::API::Middleware::Auth;
    my $mw   = Purl::API::Middleware::Auth->new;
    my $ctrl = Purl::API::Controller::Auth->new(
        storage         => MockStorage->new,
        auth_middleware => $mw,
    );
    my $c = MockAuthCtrl->new;

    $ctrl->csrf_token($c);
    my $token = $c->rendered->{json}{csrf_token};
    ok defined $token, 'token returned';
    like $token, qr/^[^:]+:\d+:[a-f0-9]+$/, 'token format: session:timestamp:hmac';

    # The token issued by the endpoint MUST verify against the same middleware.
    ok $mw->verify_csrf_token($token), 'issued token verifies with the same secret';
};

subtest 'csrf_token without middleware returns 500' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;
    $ctrl->csrf_token($c);
    is $c->rendered->{status}, 500, 'no middleware = 500, never an unsigned token';
};

# ============================================
# login — local auth
# ============================================
subtest 'login with valid local credentials' => sub {
    my $settings = MockSettings->new({
        auth => { users => { admin => 'plaintext_pass' } },
    });
    my $ctrl = Purl::API::Controller::Auth->new(
        storage         => MockStorage->new,
        settings        => $settings,
        auth_middleware  => MockAuthMiddleware->new,
    );
    my $body = encode_json({ username => 'admin', password => 'plaintext_pass' });
    my $c = MockAuthCtrl->new(body => $body);

    $ctrl->login($c);
    ok $c->rendered->{json}{authenticated}, 'login successful';
    is $c->rendered->{json}{username}, 'admin', 'username in response';
    is $c->rendered->{json}{auth_method}, 'local', 'local auth method';
    is $c->{session}{username}, 'admin', 'session username set';
    is $c->{session}{logged_in}, 1, 'session logged_in set';
};

subtest 'login with wrong password returns 401' => sub {
    my $settings = MockSettings->new({
        auth => { users => { admin => 'right_pass' } },
    });
    my $ctrl = Purl::API::Controller::Auth->new(
        storage         => MockStorage->new,
        settings        => $settings,
        auth_middleware  => MockAuthMiddleware->new,
    );
    my $body = encode_json({ username => 'admin', password => 'wrong_pass' });
    my $c = MockAuthCtrl->new(body => $body);

    $ctrl->login($c);
    is $c->rendered->{status}, 401, 'wrong password returns 401';
};

subtest 'login with unknown user returns 401' => sub {
    my $settings = MockSettings->new({
        auth => { users => { admin => 'pass' } },
    });
    my $ctrl = Purl::API::Controller::Auth->new(
        storage  => MockStorage->new,
        settings => $settings,
    );
    my $body = encode_json({ username => 'unknown', password => 'pass' });
    my $c = MockAuthCtrl->new(body => $body);

    $ctrl->login($c);
    is $c->rendered->{status}, 401, 'unknown user returns 401';
};

subtest 'login without credentials returns 400' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new(body => encode_json({}));

    $ctrl->login($c);
    is $c->rendered->{status}, 400, 'empty credentials returns 400';
};

subtest 'login records audit events' => sub {
    my $settings = MockSettings->new({
        auth => { users => { admin => 'pass' } },
    });
    my $ctrl = Purl::API::Controller::Auth->new(
        storage  => MockStorage->new,
        settings => $settings,
    );
    my $body = encode_json({ username => 'admin', password => 'pass' });
    my $c = MockAuthCtrl->new(body => $body);

    $ctrl->login($c);
    ok scalar @{$c->{audit_calls}} > 0, 'audit event recorded';
};

# ============================================
# logout
# ============================================
subtest 'logout clears session' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new(session => { username => 'admin', logged_in => 1 });

    $ctrl->logout($c);
    is $c->rendered->{json}{status}, 'ok', 'logout successful';
};

# ============================================
# me — current user info
# ============================================
subtest 'me when logged in' => sub {
    # A session is only honoured when it was issued by start_session (sid +
    # iat) for a user that still exists — see t/security_session_revocation.t.
    my $ctrl = Purl::API::Controller::Auth->new(
        storage  => MockStorage->new,
        settings => MockSettings->new({ auth => { users => { admin => 'x' } } }),
    );
    my $c = MockAuthCtrl->new(session => {
        username    => 'admin',
        logged_in   => 1,
        auth_method => 'local',
        sid         => 'a' x 32,
        iat         => time,
    });

    $ctrl->me($c);
    ok $c->rendered->{json}{authenticated}, 'authenticated true';
    is $c->rendered->{json}{username}, 'admin', 'username returned';
    is $c->rendered->{json}{auth_method}, 'local', 'auth method returned';
};

subtest 'me when not logged in' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->me($c);
    ok !$c->rendered->{json}{authenticated}, 'not authenticated';
};

# --- REGRESSION (#33): /auth/me must state whether a login is required ------
# web/src/stores/auth.js reads data.auth_required from this endpoint, but the
# backend never sent it — the name existed in exactly one file in the tree, the
# frontend one. So the login gate fell through to a guess, and on an instance
# with PURL_AUTH_ENABLED=0 and no users it could pop up a login form for
# credentials that do not exist.
subtest 'me reports auth_required in both branches' => sub {
    for my $enabled (0, 1) {
        my $settings = MockSettings->new({ auth => { enabled => $enabled, users => {} } });
        my $mw   = MockAuthMiddleware->new;
        $mw->{auth_enabled} = $enabled;
        my $ctrl = Purl::API::Controller::Auth->new(
            storage         => MockStorage->new,
            settings        => $settings,
            auth_middleware => $mw,
        );

        my $anon = MockAuthCtrl->new;
        $ctrl->me($anon);
        is ref($anon->rendered->{json}{auth_required}), 'SCALAR',
            "enabled=$enabled: anonymous branch sends a JSON boolean, not a string";
        is ${ $anon->rendered->{json}{auth_required} }, $enabled,
            "enabled=$enabled: anonymous branch reports the right value";

        my $signed_in = MockAuthCtrl->new(session => {
            username => 'admin', logged_in => 1, auth_method => 'local',
        });
        $ctrl->me($signed_in);
        is ${ $signed_in->rendered->{json}{auth_required} }, $enabled,
            "enabled=$enabled: authenticated branch reports it too";
    }
};

subtest 'auth_required survives JSON encoding as a real boolean' => sub {
    my $mw = MockAuthMiddleware->new;
    $mw->{auth_enabled} = 0;
    my $ctrl = Purl::API::Controller::Auth->new(
        storage         => MockStorage->new,
        settings        => MockSettings->new({ auth => { enabled => 0 } }),
        auth_middleware => $mw,
    );
    my $c = MockAuthCtrl->new;
    $ctrl->me($c);

    my $json = encode_json($c->rendered->{json});
    like $json, qr/"auth_required"\s*:\s*false/,
        'encodes as JSON false — "0" would be truthy in JavaScript';
};

subtest 'me falls back to settings when no middleware is wired' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(
        storage  => MockStorage->new,
        settings => MockSettings->new({ auth => { enabled => 1 } }),
    );
    my $c = MockAuthCtrl->new;
    $ctrl->me($c);
    is ${ $c->rendered->{json}{auth_required} }, 1, 'read straight from settings';
};

# ============================================
# sso_login — SAML redirect
# ============================================
subtest 'sso_login without SAML middleware returns 503' => sub {
    my $ctrl = Purl::API::Controller::SSO->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_login($c);
    is $c->rendered->{status}, 503, 'no SAML = 503';
};

subtest 'sso_login with unavailable SAML returns 503' => sub {
    my $mock_saml = bless {}, 'MockSAMLUnavail';
    no warnings 'once';
    *MockSAMLUnavail::is_available = sub { 0 };
    my $ctrl = Purl::API::Controller::SSO->new(
        storage         => MockStorage->new,
        saml_middleware => $mock_saml,
    );
    my $c = MockAuthCtrl->new;

    $ctrl->sso_login($c);
    is $c->rendered->{status}, 503, 'unavailable SAML = 503';
};

# ============================================
# sso_callback — SAML assertion
# ============================================
subtest 'sso_callback without SAML middleware returns 503' => sub {
    my $ctrl = Purl::API::Controller::SSO->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_callback($c);
    is $c->rendered->{status}, 503, 'no SAML = 503';
};

subtest 'sso_callback without SAMLResponse returns 400' => sub {
    my $mock_saml = bless {}, 'MockSAMLCB';
    no warnings 'once';
    *MockSAMLCB::is_available = sub { 1 };
    my $ctrl = Purl::API::Controller::SSO->new(
        storage         => MockStorage->new,
        saml_middleware => $mock_saml,
    );
    my $c = MockAuthCtrl->new;

    $ctrl->sso_callback($c);
    is $c->rendered->{status}, 400, 'missing SAMLResponse = 400';
};

# ============================================
# sso_metadata
# ============================================
subtest 'sso_metadata without SAML returns 404' => sub {
    my $ctrl = Purl::API::Controller::SSO->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_metadata($c);
    is $c->rendered->{status}, 404, 'no SAML = 404';
};

done_testing;

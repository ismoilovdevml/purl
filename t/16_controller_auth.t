#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Auth;

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
    sub new { bless {}, $_[0] }
    sub verify_password {
        my ($self, $pass, $stored) = @_;
        # Simple mock: returns (valid, new_hash) like bcrypt version
        return $pass eq 'correctpassword' ? (1, undef) : (0, undef);
    }
    sub hash_password { '$2b$12$' . ('a' x 53) }

    package MockSettings;
    sub new { bless { sections => $_[1] // {} }, $_[0] }
    sub get_section { $_[0]->{sections}{$_[1]} // {} }
    sub set_section { $_[0]->{sections}{$_[1]} = $_[2] }

    package MockStorage;
    sub new { bless {}, $_[0] }
}

# ============================================
# csrf_token
# ============================================
subtest 'csrf_token returns token' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->csrf_token($c);
    my $token = $c->rendered->{json}{csrf_token};
    ok defined $token, 'token returned';
    like $token, qr/^[^:]+:\d+:[a-f0-9]+$/, 'token format: session:timestamp:hmac';
};

# ============================================
# verify_csrf_token
# ============================================
subtest 'verify_csrf_token valid' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $token = $ctrl->_generate_csrf_token('test_session');
    ok $ctrl->verify_csrf_token($token), 'valid token verified';
};

subtest 'verify_csrf_token invalid' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    ok !$ctrl->verify_csrf_token('invalid'), 'invalid token rejected';
    ok !$ctrl->verify_csrf_token(undef), 'undef rejected';
    ok !$ctrl->verify_csrf_token(''), 'empty rejected';
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
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new(session => {
        username    => 'admin',
        logged_in   => 1,
        auth_method => 'local',
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

# ============================================
# sso_login — SAML redirect
# ============================================
subtest 'sso_login without SAML middleware returns 503' => sub {
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_login($c);
    is $c->rendered->{status}, 503, 'no SAML = 503';
};

subtest 'sso_login with unavailable SAML returns 503' => sub {
    my $mock_saml = bless {}, 'MockSAMLUnavail';
    no warnings 'once';
    *MockSAMLUnavail::is_available = sub { 0 };
    my $ctrl = Purl::API::Controller::Auth->new(
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
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_callback($c);
    is $c->rendered->{status}, 503, 'no SAML = 503';
};

subtest 'sso_callback without SAMLResponse returns 400' => sub {
    my $mock_saml = bless {}, 'MockSAMLCB';
    no warnings 'once';
    *MockSAMLCB::is_available = sub { 1 };
    my $ctrl = Purl::API::Controller::Auth->new(
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
    my $ctrl = Purl::API::Controller::Auth->new(storage => MockStorage->new);
    my $c = MockAuthCtrl->new;

    $ctrl->sso_metadata($c);
    is $c->rendered->{status}, 404, 'no SAML = 404';
};

done_testing;

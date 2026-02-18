#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ---------------------------------------------------------------------------
# Pre-register Net::SAML2 namespaces so Test::MockModule can intercept them
# even when the real modules are not installed.
# ---------------------------------------------------------------------------

BEGIN {
    for my $pkg (qw(
        Net::SAML2::IdP
        Net::SAML2::SP
        Net::SAML2::Binding::Redirect
        Net::SAML2::Binding::POST
        Net::SAML2::Protocol::Assertion
    )) {
        (my $file = $pkg) =~ s{::}{/}g;
        $file .= '.pm';
        $INC{$file} = 1;
    }
}

# ---------------------------------------------------------------------------
# Minimal mock objects for Net::SAML2 internals
# ---------------------------------------------------------------------------

# MockAuthnReq: simulates the return value of SP->authn_request()
package MockAuthnReq;
sub new     { bless {}, $_[0] }
sub as_xml  { '<samlp:AuthnRequest>mock</samlp:AuthnRequest>' }

# MockSP: simulates a Net::SAML2::SP object
package MockSP;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub authn_request { MockAuthnReq->new }
sub metadata      { '<md:EntityDescriptor>mock-metadata</md:EntityDescriptor>' }

# MockRedirect: simulates Net::SAML2::Binding::Redirect
package MockRedirect;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub sign { 'https://idp.example.com/sso?SAMLRequest=encoded&RelayState=dashboard' }

# MockPOSTBinding: simulates Net::SAML2::Binding::POST
package MockPOSTBinding;
sub new {
    my ($class, %args) = @_;
    return bless { %args }, $class;
}
sub handle_response { '<saml:Assertion>mock-assertion-xml</saml:Assertion>' }

# MockAssertion: simulates Net::SAML2::Protocol::Assertion
package MockAssertion;
sub new_from_xml {
    my ($class, %args) = @_;
    return bless {
        nameid     => 'john@corp.com',
        attributes => {
            email  => ['john@corp.com'],
            groups => ['admins', 'developers'],
        },
        audience   => 'https://purl.example.com',
        issuer     => 'https://idp.example.com',
        _expired   => 0,
        _not_before => 0,
        _valid     => 1,
    }, $class;
}
sub nameid      { $_[0]->{nameid} }
sub attributes  { $_[0]->{attributes} }
sub audience    { $_[0]->{audience} }
sub issuer      { $_[0]->{issuer} }
sub has_expired { $_[0]->{_expired} }
sub not_before  { $_[0]->{_not_before} }
sub valid       { $_[0]->{_valid} }

# Back to the test package
package main;

# ---------------------------------------------------------------------------
# Standard SAML config reused across multiple subtests
# ---------------------------------------------------------------------------

my $SAML_CONFIG = {
    enabled        => 1,
    entity_id      => 'https://purl.example.com',
    idp_entity_id  => 'https://idp.example.com',
    idp_sso_url    => 'https://idp.example.com/sso',
    idp_slo_url    => 'https://idp.example.com/slo',
    idp_cert       => '-----BEGIN CERTIFICATE-----mock-----END CERTIFICATE-----',
    acs_url        => 'https://purl.example.com/api/auth/sso/callback',
    name_id_format => 'emailAddress',
    sign_requests  => 0,
    sp_cert        => '',
    sp_key         => '',
    username_attr  => 'email',
    groups_attr    => 'groups',
    allowed_groups => '',
    force_authn    => 0,
};

# Helper: set up standard mocks for validate_response tests
sub _setup_validate_mocks {
    my (%opts) = @_;

    my $mock_sp        = Test::MockModule->new('Net::SAML2::SP');
    my $mock_post      = Test::MockModule->new('Net::SAML2::Binding::POST');
    my $mock_assertion = Test::MockModule->new('Net::SAML2::Protocol::Assertion');

    $mock_sp->mock('new', sub { MockSP->new });
    $mock_post->mock('new', sub { MockPOSTBinding->new });

    my $assertion_builder = $opts{assertion_builder} // sub { MockAssertion->new_from_xml };
    $mock_assertion->mock('new_from_xml', $assertion_builder);

    return ($mock_sp, $mock_post, $mock_assertion);
}

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------

use_ok('Purl::API::Middleware::SAML') or BAIL_OUT('Module failed to load');

# ===========================================================================
# 1. is_available — fully configured
# ===========================================================================

subtest 'is_available - fully configured' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { MockSP->new });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    ok($saml->is_available, 'returns 1 when fully configured and SP builds');
};

# ===========================================================================
# 2. is_available — missing required fields
# ===========================================================================

subtest 'is_available - missing required fields' => sub {
    for my $field (qw(idp_sso_url idp_cert entity_id acs_url)) {
        my $cfg = { %$SAML_CONFIG, $field => '' };
        my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
        ok(!$saml->is_available, "returns 0 when $field is empty");
    }
};

# ===========================================================================
# 3. is_available — SP constructor dies
# ===========================================================================

subtest 'is_available - SP constructor dies' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { die "SP initialization failed\n" });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $available;

    eval { $available = $saml->is_available };
    ok(!$@, 'does not propagate exception');
    ok(!$available, 'returns 0 when SP constructor dies');
};

# ===========================================================================
# 4. build_authn_request — success
# ===========================================================================

subtest 'build_authn_request - success' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    my $mock_redirect = Test::MockModule->new('Net::SAML2::Binding::Redirect');

    $mock_sp->mock('new', sub { MockSP->new });
    $mock_redirect->mock('new', sub { MockRedirect->new });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->build_authn_request('/dashboard');

    ok($result->{success}, 'success flag is true');
    like($result->{redirect_url}, qr/^https:\/\//, 'redirect_url starts with https');
    like($result->{redirect_url}, qr/SAMLRequest/, 'redirect_url contains SAMLRequest param');
    like($result->{redirect_url}, qr/RelayState/, 'redirect_url contains RelayState param');
};

# ===========================================================================
# 5. build_authn_request — SP unavailable
# ===========================================================================

subtest 'build_authn_request - SP unavailable' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { die "Cannot build SP\n" });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->build_authn_request('/dashboard');

    ok(!$result->{success}, 'success is false when SP unavailable');
    ok(defined $result->{error}, 'error message is present');
    ok($result->{unavailable}, 'unavailable flag is set');
};

# ===========================================================================
# 6. build_authn_request — missing IdP SSO URL
# ===========================================================================

subtest 'build_authn_request - missing IdP SSO URL' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { MockSP->new });

    my $cfg = { %$SAML_CONFIG, idp_sso_url => '' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->build_authn_request('/dashboard');

    ok(!$result->{success}, 'success is false when idp_sso_url empty');
    like($result->{error}, qr/not configured/i, 'error mentions URL not configured');
};

# ===========================================================================
# 7. validate_response — successful assertion
# ===========================================================================

subtest 'validate_response - successful assertion' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks();

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock-assertion-xml</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response', '/dashboard');

    ok($result->{success}, 'success flag is true');
    is($result->{username}, 'john@corp.com', 'username extracted from assertion');
    is($result->{email}, 'john@corp.com', 'email extracted from assertion');
    is_deeply(
        $result->{groups},
        ['admins', 'developers'],
        'groups extracted from assertion attributes',
    );
};

# ===========================================================================
# 8. validate_response — empty SAMLResponse
# ===========================================================================

subtest 'validate_response - empty SAMLResponse' => sub {
    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);

    # undef
    my $result;
    eval { $result = $saml->validate_response(undef) };
    ok(!$@, 'no exception when SAMLResponse is undef');
    ok(!$result->{success}, 'success is false for undef response');

    # empty string
    my $result2 = $saml->validate_response('');
    ok(!$result2->{success}, 'success is false for empty string response');
    like($result2->{error}, qr/[Ee]mpty/, 'error mentions empty');
};

# ===========================================================================
# 9. validate_response — audience mismatch
# ===========================================================================

subtest 'validate_response - audience mismatch' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{audience} = 'https://wrong-audience.example.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false when audience does not match entity_id');
    like($result->{error}, qr/[Aa]udience/i, 'error mentions audience restriction');
};

# ===========================================================================
# 10. validate_response — issuer mismatch
# ===========================================================================

subtest 'validate_response - issuer mismatch' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{issuer} = 'https://evil-idp.example.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false when issuer does not match idp_entity_id');
    like($result->{error}, qr/[Ii]ssuer/i, 'error mentions issuer mismatch');
};

# ===========================================================================
# 11. validate_response — expired assertion
# ===========================================================================

subtest 'validate_response - expired assertion' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{_expired} = 1;
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false for expired assertion');
    like($result->{error}, qr/expir/i, 'error mentions expiration');
};

# ===========================================================================
# 12. validate_response — not yet valid assertion
# ===========================================================================

subtest 'validate_response - not yet valid assertion' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{_not_before} = 1;
            $a->{_valid} = 0;
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false when assertion is not yet valid');
    like($result->{error}, qr/not yet valid/i, 'error mentions not yet valid');
};

# ===========================================================================
# 13. validate_response — missing username (no attribute, no nameid)
# ===========================================================================

subtest 'validate_response - missing username' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{nameid} = '';
            $a->{attributes} = { groups => ['admins'] };
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false when username cannot be determined');
    like($result->{error}, qr/username/i, 'error mentions username');
};

# ===========================================================================
# 14. validate_response — username falls back to nameid
# ===========================================================================

subtest 'validate_response - username falls back to nameid' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            # email attr missing, but nameid is set
            $a->{attributes} = { groups => ['devs'] };
            $a->{nameid} = 'jane@corp.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok($result->{success}, 'success when username falls back to nameid');
    is($result->{username}, 'jane@corp.com', 'username is nameid value');
};

# ===========================================================================
# 15. validate_response — email fallback from username with @
# ===========================================================================

subtest 'validate_response - email fallback from username containing @' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            # No email/mail/Email attr, but username (from 'uid' attr) contains @
            $a->{attributes} = {
                uid    => ['alice@corp.com'],
                groups => ['staff'],
            };
            $a->{nameid} = 'alice@corp.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $cfg = { %$SAML_CONFIG, username_attr => 'uid' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok($result->{success}, 'success when email derived from username');
    is($result->{email}, 'alice@corp.com', 'email extracted from username containing @');
};

# ===========================================================================
# 16. validate_response — email fallback when username has no @
# ===========================================================================

subtest 'validate_response - no email when username lacks @' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{attributes} = {
                uid    => ['alice'],
                groups => ['staff'],
            };
            $a->{nameid} = 'alice';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $cfg = { %$SAML_CONFIG, username_attr => 'uid' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok($result->{success}, 'success even without email');
    is($result->{email}, '', 'email is empty when username has no @');
};

# ===========================================================================
# 17. validate_response — group not in allowlist
# ===========================================================================

subtest 'validate_response - group not in allowlist' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{attributes} = {
                email  => ['viewer@corp.com'],
                groups => ['viewers'],
            };
            $a->{nameid} = 'viewer@corp.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $cfg = { %$SAML_CONFIG, allowed_groups => 'admins' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok(!$result->{success}, 'success is false when user group not in allowlist');
    like($result->{error}, qr/group/i, 'error mentions group');
};

# ===========================================================================
# 18. validate_response — group in allowlist (multiple allowed)
# ===========================================================================

subtest 'validate_response - group matches one of multiple allowed' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{attributes} = {
                email  => ['dev@corp.com'],
                groups => ['developers'],
            };
            $a->{nameid} = 'dev@corp.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $cfg = { %$SAML_CONFIG, allowed_groups => 'admins, developers, ops' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok($result->{success}, 'success when user in one of multiple allowed groups');
    is($result->{username}, 'dev@corp.com', 'username correct');
};

# ===========================================================================
# 19. validate_response — empty allowed_groups allows everyone
# ===========================================================================

subtest 'validate_response - empty allowed_groups allows everyone' => sub {
    my ($mock_sp, $mock_post, $mock_assertion) = _setup_validate_mocks(
        assertion_builder => sub {
            my $a = MockAssertion->new_from_xml;
            $a->{attributes} = {
                email  => ['random@corp.com'],
                groups => ['some-random-group'],
            };
            $a->{nameid} = 'random@corp.com';
            return $a;
        },
    );

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        return '<saml:Assertion>mock</saml:Assertion>';
    };
    use warnings 'redefine';

    my $cfg = { %$SAML_CONFIG, allowed_groups => '' };
    my $saml = Purl::API::Middleware::SAML->new(config => $cfg);
    my $result = $saml->validate_response('base64-encoded-saml-response');

    ok($result->{success}, 'success when allowed_groups is empty (no restriction)');
};

# ===========================================================================
# 20. validate_response — binding dies
# ===========================================================================

subtest 'validate_response - binding dies' => sub {
    my $mock_sp   = Test::MockModule->new('Net::SAML2::SP');
    my $mock_post = Test::MockModule->new('Net::SAML2::Binding::POST');

    $mock_sp->mock('new', sub { MockSP->new });
    $mock_post->mock('new', sub { MockPOSTBinding->new });

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub {
        die "XML signature verification failed\n";
    };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result;

    eval { $result = $saml->validate_response('base64-encoded-saml-response') };
    ok(!$@, 'no uncaught exception when binding dies');
    ok(!$result->{success}, 'success is false when binding dies');
    ok(defined $result->{error}, 'error message is present');
};

# ===========================================================================
# 21. validate_response — handle_response returns undef
# ===========================================================================

subtest 'validate_response - handle_response returns undef' => sub {
    my $mock_sp   = Test::MockModule->new('Net::SAML2::SP');
    my $mock_post = Test::MockModule->new('Net::SAML2::Binding::POST');

    $mock_sp->mock('new', sub { MockSP->new });
    $mock_post->mock('new', sub { MockPOSTBinding->new });

    no warnings 'redefine';
    local *MockPOSTBinding::handle_response = sub { undef };
    use warnings 'redefine';

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('bad-saml-data');

    ok(!$result->{success}, 'success is false when handle_response returns undef');
    like($result->{error}, qr/parse|response/i, 'error mentions parsing failure');
};

# ===========================================================================
# 22. validate_response — SP unavailable during validation
# ===========================================================================

subtest 'validate_response - SP unavailable' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { die "SP gone\n" });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $result = $saml->validate_response('base64-data');

    ok(!$result->{success}, 'success is false when SP unavailable');
    ok($result->{unavailable}, 'unavailable flag is set');
};

# ===========================================================================
# 23. generate_metadata — success
# ===========================================================================

subtest 'generate_metadata - success' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { MockSP->new });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $metadata = $saml->generate_metadata;

    ok(defined $metadata, 'metadata is defined');
    like($metadata, qr/EntityDescriptor/, 'metadata contains EntityDescriptor');
};

# ===========================================================================
# 24. generate_metadata — SP unavailable
# ===========================================================================

subtest 'generate_metadata - SP unavailable' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');
    $mock_sp->mock('new', sub { die "SP build failed\n" });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $metadata;

    eval { $metadata = $saml->generate_metadata };
    ok(!$@, 'does not propagate exception');
    ok(!defined $metadata, 'metadata is undef when SP unavailable');
};

# ===========================================================================
# 25. generate_metadata — metadata() throws
# ===========================================================================

subtest 'generate_metadata - metadata() throws' => sub {
    my $mock_sp = Test::MockModule->new('Net::SAML2::SP');

    # SP builds OK but metadata() call dies
    my $broken_sp = MockSP->new;
    no warnings 'redefine';
    local *MockSP::metadata = sub { die "serialization error\n" };
    use warnings 'redefine';

    $mock_sp->mock('new', sub { $broken_sp });

    my $saml = Purl::API::Middleware::SAML->new(config => $SAML_CONFIG);
    my $metadata;

    eval { $metadata = $saml->generate_metadata };
    ok(!$@, 'does not propagate exception from metadata()');
    ok(!defined $metadata, 'returns undef when metadata() throws');
};

done_testing;

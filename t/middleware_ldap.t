#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use Test::MockModule;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ---------------------------------------------------------------------------
# Minimal mock objects for Net::LDAP internals
# ---------------------------------------------------------------------------

# MockMessage: simulates the return value of bind() and unbind()
package MockMessage;
sub new {
    my ($class, %args) = @_;
    return bless { code => $args{code} // 0, error => $args{error} // '' }, $class;
}
sub code     { $_[0]->{code} }
sub error    { $_[0]->{error} }
sub is_error { $_[0]->{code} != 0 ? 1 : 0 }

# MockEntry: simulates a single LDAP search result entry
package MockEntry;
sub new {
    my ($class, $dn, $attrs) = @_;
    return bless { dn => $dn, attrs => $attrs // {} }, $class;
}
sub dn        { $_[0]->{dn} }
sub get_value { $_[0]->{attrs}{ $_[1] } }

# MockSearch: simulates the return value of search()
package MockSearch;
sub new {
    my ($class, %args) = @_;
    return bless {
        count   => $args{count}   // 0,
        entries => $args{entries} // [],
        code    => $args{code}    // 0,
        error   => $args{error}   // '',
    }, $class;
}
sub count    { $_[0]->{count} }
sub entries  { @{ $_[0]->{entries} } }
sub entry    { $_[0]->{entries}[ $_[1] ] }
sub code     { $_[0]->{code} }
sub error    { $_[0]->{error} }
sub is_error { $_[0]->{code} != 0 ? 1 : 0 }

# MockLDAP: simulates a Net::LDAP connection object
package MockLDAP;
sub new { bless {}, $_[0] }

# Back to the test package
package main;

# ---------------------------------------------------------------------------
# Standard AD config reused across multiple subtests
# ---------------------------------------------------------------------------

my $AD_CONFIG = {
    server        => 'ldap://dc.corp.com',
    port          => 389,
    bind_dn       => 'CN=svc,DC=corp,DC=com',
    bind_password => 'secret',
    search_base   => 'DC=corp,DC=com',
    user_attr     => 'sAMAccountName',
    mail_attr     => 'mail',
    group_attr    => 'memberOf',
    mode          => 'ad',
    timeout       => 5,
    tls_enabled   => 0,
};

# ---------------------------------------------------------------------------
# Load the module under test
# ---------------------------------------------------------------------------

use_ok('Purl::API::Middleware::LDAP') or BAIL_OUT('Module failed to load');

# ===========================================================================
# 1. escape_filter — injection prevention
# ===========================================================================

subtest 'escape_filter - injection prevention' => sub {
    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    # Characters that MUST be escaped per RFC 4515:
    #   *  ->  \2a
    #   (  ->  \28
    #   )  ->  \29
    #   \  ->  \5c
    #  NUL ->  \00
    my $dangerous = "admin*)(uid=*))(|(uid=*";
    my $escaped   = $ldap->escape_filter($dangerous);

    # No unescaped wildcard or parentheses should survive
    unlike($escaped, qr/(?<!\\)\*/,   'wildcard * is escaped');
    unlike($escaped, qr/(?<!\\)\(/,   'open paren ( is escaped');
    unlike($escaped, qr/(?<!\\)\)/,   'close paren ) is escaped');

    # The raw injection string must not appear verbatim
    isnt($escaped, $dangerous, 'dangerous string is transformed');

    # Verify each special char was individually escaped
    like($escaped, qr/\\2a/i, 'asterisk encoded as \\2a');
    like($escaped, qr/\\28/i, 'open paren encoded as \\28');
    like($escaped, qr/\\29/i, 'close paren encoded as \\29');

    # Backslash escape
    my $with_backslash = 'C:\\admin';
    my $esc_bs         = $ldap->escape_filter($with_backslash);
    like($esc_bs, qr/\\5c/i, 'backslash encoded as \\5c');

    # NUL byte escape
    my $with_nul = "user\x00name";
    my $esc_nul  = $ldap->escape_filter($with_nul);
    like($esc_nul, qr/\\00/i, 'NUL byte encoded as \\00');

    # Safe username must pass through unchanged
    my $safe     = 'john';
    my $esc_safe = $ldap->escape_filter($safe);
    is($esc_safe, 'john', 'safe username "john" is unchanged');
};

# ===========================================================================
# 2. authenticate — successful AD login
# ===========================================================================

subtest 'authenticate - successful AD login' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    # Service account bind succeeds (code 0)
    my $svc_bind_result  = MockMessage->new(code => 0);
    # User bind also succeeds (code 0)
    my $user_bind_result = MockMessage->new(code => 0);

    my $entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        {
            mail     => 'john@corp.com',
            memberOf => 'CN=PurlAdmins,DC=corp,DC=com',
        },
    );

    my $search_result = MockSearch->new(
        count   => 1,
        entries => [$entry],
    );

    # Track bind() call order so we return the right mock each time
    my $bind_call = 0;
    my $mock_obj  = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    # Override bind() on the mock object class dynamically
    no warnings 'redefine';
    local *MockLDAP::bind = sub {
        $bind_call++;
        return $bind_call == 1 ? $svc_bind_result : $user_bind_result;
    };
    local *MockLDAP::search  = sub { $search_result };
    local *MockLDAP::unbind  = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password123');

    ok($result->{success},              'success flag is true');
    is($result->{dn},   'CN=John,DC=corp,DC=com', 'DN matches entry');
    is($result->{mail}, 'john@corp.com',           'mail attribute extracted');
    is_deeply(
        $result->{groups},
        ['PurlAdmins'],
        'groups list: CN extracted from full AD memberOf DN',
    );
};

# ===========================================================================
# 3. authenticate — wrong password (bind code 49)
# ===========================================================================

subtest 'authenticate - wrong password' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $svc_bind_ok   = MockMessage->new(code => 0);
    my $user_bind_err = MockMessage->new(code => 49);   # 49 = invalidCredentials

    my $entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        { mail => 'john@corp.com', memberOf => '' },
    );

    my $search_result = MockSearch->new(count => 1, entries => [$entry]);

    my $bind_call = 0;
    my $mock_obj  = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub {
        $bind_call++;
        return $bind_call == 1 ? $svc_bind_ok : $user_bind_err;
    };
    local *MockLDAP::search = sub { $search_result };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'wrongpassword');

    ok(!$result->{success}, 'success flag is false for bad password');
    is($result->{error}, 'Invalid credentials', 'error message is "Invalid credentials"');
};

# ===========================================================================
# 4. authenticate — user not found (search returns 0 entries)
# ===========================================================================

subtest 'authenticate - user not found' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $svc_bind_ok = MockMessage->new(code => 0);
    my $empty_search = MockSearch->new(count => 0, entries => []);

    my $mock_obj = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { $svc_bind_ok };
    local *MockLDAP::search = sub { $empty_search };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('ghost', 'anything');

    ok(!$result->{success}, 'success flag is false when user not found');
    # Returns 'Invalid credentials' (not 'User not found') to prevent username enumeration
    is($result->{error}, 'Invalid credentials', 'error is "Invalid credentials" (prevents username enumeration)');
};

# ===========================================================================
# 5. authenticate — service account bind fails (code 32)
# ===========================================================================

subtest 'authenticate - service account bind fails' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    # code 32 = noSuchObject / misconfigured service account
    my $svc_bind_fail = MockMessage->new(code => 32);

    my $mock_obj = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { $svc_bind_fail };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok(!$result->{success}, 'success flag is false when service account bind fails');
    like(
        $result->{error},
        qr/service account/i,
        'error message mentions "service account"',
    );
};

# ===========================================================================
# 6. authenticate — LDAP server unavailable (Net::LDAP->new returns undef)
# ===========================================================================

subtest 'authenticate - LDAP server unavailable' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    # Simulate connection failure: new() returns undef
    $mock_ldap_module->mock('new', sub { undef });

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok(!$result->{success},    'success flag is false when server unavailable');
    ok($result->{unavailable}, 'unavailable flag is set');
};

subtest 'authenticate - LDAP server unavailable (new() dies)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    # Simulate connection failure: new() throws an exception
    $mock_ldap_module->mock('new', sub { die "Connection refused\n" });

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    # authenticate() must NOT propagate the exception
    eval { $result = $ldap->authenticate('john', 'password') };
    ok(!$@, 'no uncaught exception propagated when new() dies');

    ok(defined $result,        'result hashref is returned');
    ok(!$result->{success},    'success flag is false');
    ok($result->{unavailable}, 'unavailable flag is set');
};

# ===========================================================================
# 7. is_available — server up
# ===========================================================================

subtest 'is_available - server up' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $bind_ok  = MockMessage->new(code => 0);
    my $mock_obj = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { $bind_ok };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    my $available = $ldap->is_available;
    ok($available, 'is_available returns true (1) when server responds');
};

# ===========================================================================
# 8. is_available — server down (new() dies)
# ===========================================================================

subtest 'is_available - server down' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    $mock_ldap_module->mock('new', sub { die "Connection refused\n" });

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    my $available;

    # is_available() must NOT die — it should handle the error internally
    eval { $available = $ldap->is_available };
    ok(!$@, 'is_available does not propagate exception when server is down');

    ok(!$available, 'is_available returns false (0) when server is unreachable');
};

# ===========================================================================
# 9. search_filter — username interpolation
# ===========================================================================

subtest 'search_filter - username interpolation' => sub {
    # Config with a custom search filter template
    my $config = {
        %$AD_CONFIG,
        search_filter => '({user_attr}={username})',
        user_attr     => 'uid',
    };

    # We intercept search() to capture the filter string that was actually used
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $bind_ok      = MockMessage->new(code => 0);
    my $empty_search = MockSearch->new(count => 0, entries => []);
    my $mock_obj     = MockLDAP->new;
    my $captured_filter;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind  = sub { $bind_ok };
    local *MockLDAP::search = sub {
        my ($self, %args) = @_;
        $captured_filter = $args{filter};
        return $empty_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $config);
    $ldap->authenticate('alice', 'pass');

    # After interpolation: ({user_attr}={username}) → (uid=alice)
    is($captured_filter, '(uid=alice)',
        'search filter interpolates {user_attr} and {username} correctly');
};

# ===========================================================================
# 10. authenticate — eval safety (no uncaught exceptions)
# ===========================================================================

subtest 'authenticate - eval safety (no uncaught exceptions)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    # bind() throws an arbitrary runtime exception
    no warnings 'redefine';
    local *MockLDAP::bind = sub { die "Unexpected internal LDAP error\n" };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    # The call MUST NOT propagate the exception out of authenticate()
    eval { $result = $ldap->authenticate('john', 'password') };

    ok(!$@, 'authenticate() does not propagate arbitrary exception from bind()');
    ok(defined $result, 'authenticate() returns a hashref even after internal exception');
    is(ref $result, 'HASH', 'returned value is a HASH reference');
    ok(!$result->{success}, 'success flag is false when internal exception occurs');
};

done_testing;

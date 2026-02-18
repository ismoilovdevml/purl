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

# MockMessage: simulates the return value of bind(), unbind(), start_tls()
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
sub dn { $_[0]->{dn} }
sub get_value {
    my ($self, $attr) = @_;
    my $val = $self->{attrs}{$attr};
    return unless defined $val;
    # In list context return array, in scalar return first value
    if (ref $val eq 'ARRAY') {
        return wantarray ? @$val : $val->[0];
    }
    return $val;
}

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
sub disconnect { 1 }

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

my $OPENLDAP_CONFIG = {
    server        => 'ldap://ldap.corp.com',
    port          => 389,
    bind_dn       => 'cn=admin,dc=corp,dc=com',
    bind_password => 'secret',
    search_base   => 'ou=people,dc=corp,dc=com',
    user_attr     => 'uid',
    mail_attr     => 'mail',
    group_attr    => 'member',
    mode          => 'openldap',
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

    my $dangerous = "admin*)(uid=*))(|(uid=*";
    my $escaped   = $ldap->escape_filter($dangerous);

    unlike($escaped, qr/(?<!\\)\*/,   'wildcard * is escaped');
    unlike($escaped, qr/(?<!\\)\(/,   'open paren ( is escaped');
    unlike($escaped, qr/(?<!\\)\)/,   'close paren ) is escaped');
    isnt($escaped, $dangerous, 'dangerous string is transformed');

    like($escaped, qr/\\2a/i, 'asterisk encoded as \\2a');
    like($escaped, qr/\\28/i, 'open paren encoded as \\28');
    like($escaped, qr/\\29/i, 'close paren encoded as \\29');

    # Backslash
    my $esc_bs = $ldap->escape_filter('C:\\admin');
    like($esc_bs, qr/\\5c/i, 'backslash encoded as \\5c');

    # NUL byte
    my $esc_nul = $ldap->escape_filter("user\x00name");
    like($esc_nul, qr/\\00/i, 'NUL byte encoded as \\00');

    # Safe username unchanged
    is($ldap->escape_filter('john'), 'john', 'safe username unchanged');
};

# ===========================================================================
# 2. escape_filter — edge cases
# ===========================================================================

subtest 'escape_filter - edge cases' => sub {
    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    # undef returns empty string
    is($ldap->escape_filter(undef), '', 'undef returns empty string');

    # empty string returns empty string
    is($ldap->escape_filter(''), '', 'empty string returns empty string');

    # Multiple special chars in one string
    my $multi = $ldap->escape_filter('a*b(c)d\\e');
    unlike($multi, qr/(?<!\\)[*()\x00]/, 'all special chars escaped in combined string');
};

# ===========================================================================
# 3. authenticate — empty username / empty password
# ===========================================================================

subtest 'authenticate - empty username' => sub {
    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    my $result = $ldap->authenticate('', 'password123');
    ok(!$result->{success}, 'fails with empty username');
    like($result->{error}, qr/[Uu]sername.*required/i, 'error mentions username required');

    my $result2 = $ldap->authenticate(undef, 'password123');
    ok(!$result2->{success}, 'fails with undef username');
};

subtest 'authenticate - empty password' => sub {
    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    my $result = $ldap->authenticate('john', '');
    ok(!$result->{success}, 'fails with empty password');
    like($result->{error}, qr/[Pp]assword.*required/i, 'error mentions password required');

    my $result2 = $ldap->authenticate('john', undef);
    ok(!$result2->{success}, 'fails with undef password');
};

# ===========================================================================
# 4. authenticate — successful AD login
# ===========================================================================

subtest 'authenticate - successful AD login' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $svc_bind_result  = MockMessage->new(code => 0);
    my $user_bind_result = MockMessage->new(code => 0);

    my $user_entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        {
            mail     => 'john@corp.com',
            memberOf => 'CN=PurlAdmins,DC=corp,DC=com',
        },
    );

    my $search_result = MockSearch->new(count => 1, entries => [$user_entry]);

    # AD group lookup entry (same user, read memberOf)
    my $group_entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        {
            memberOf => ['CN=PurlAdmins,DC=corp,DC=com'],
        },
    );
    my $group_search = MockSearch->new(count => 1, entries => [$group_entry]);

    my $bind_call   = 0;
    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub {
        $bind_call++;
        return $bind_call == 1 ? $svc_bind_result : $user_bind_result;
    };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_call == 1 ? $search_result : $group_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password123');

    ok($result->{success}, 'success flag is true');
    is($result->{dn}, 'CN=John,DC=corp,DC=com', 'DN matches entry');
    is($result->{mail}, 'john@corp.com', 'mail attribute extracted');
    is_deeply($result->{groups}, ['PurlAdmins'],
        'groups: CN extracted from AD memberOf DN');
};

# ===========================================================================
# 5. authenticate — multiple AD groups
# ===========================================================================

subtest 'authenticate - multiple AD groups' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $user_entry = MockEntry->new(
        'CN=Alice,DC=corp,DC=com',
        { mail => 'alice@corp.com' },
    );
    my $search_result = MockSearch->new(count => 1, entries => [$user_entry]);

    # AD group entry with multiple memberOf values
    my $group_entry = MockEntry->new(
        'CN=Alice,DC=corp,DC=com',
        {
            memberOf => [
                'CN=Developers,OU=Groups,DC=corp,DC=com',
                'CN=QA Team,OU=Groups,DC=corp,DC=com',
                'CN=VPN Users,OU=Groups,DC=corp,DC=com',
            ],
        },
    );
    my $group_search = MockSearch->new(count => 1, entries => [$group_entry]);

    my $bind_call   = 0;
    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_call == 1 ? $search_result : $group_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('alice', 'pass');

    ok($result->{success}, 'success for multi-group user');
    is_deeply(
        $result->{groups},
        ['Developers', 'QA Team', 'VPN Users'],
        'all group CNs extracted from multiple memberOf DNs',
    );
};

# ===========================================================================
# 6. authenticate — wrong password (bind code 49)
# ===========================================================================

subtest 'authenticate - wrong password (bind code 49)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        { mail => 'john@corp.com' },
    );
    my $search_result = MockSearch->new(count => 1, entries => [$entry]);

    my $bind_call = 0;
    my $mock_obj  = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub {
        $bind_call++;
        return $bind_call == 1
            ? MockMessage->new(code => 0)    # svc bind OK
            : MockMessage->new(code => 49);  # user bind: invalidCredentials
    };
    local *MockLDAP::search = sub { $search_result };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'wrongpassword');

    ok(!$result->{success}, 'success is false for bad password');
    is($result->{error}, 'Invalid credentials', 'error is "Invalid credentials"');
};

# ===========================================================================
# 7. authenticate — user not found (0 entries)
# ===========================================================================

subtest 'authenticate - user not found' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $empty_search = MockSearch->new(count => 0, entries => []);
    my $mock_obj     = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub { $empty_search };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('ghost', 'anything');

    ok(!$result->{success}, 'success is false');
    is($result->{error}, 'Invalid credentials',
        'returns "Invalid credentials" (prevents username enumeration)');
    ok(!$result->{unavailable}, 'not marked as unavailable (it is a user error)');
};

# ===========================================================================
# 8. authenticate — service account bind fails (code 32)
# ===========================================================================

subtest 'authenticate - service account bind fails' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 32) };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok(!$result->{success}, 'success is false');
    like($result->{error}, qr/service account/i, 'error mentions service account');
    ok($result->{unavailable}, 'marked as unavailable (infrastructure issue)');
};

# ===========================================================================
# 9. authenticate — LDAP server unavailable (new returns undef)
# ===========================================================================

subtest 'authenticate - server unavailable (new returns undef)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');
    $mock_ldap_module->mock('new', sub { undef });

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok(!$result->{success}, 'success is false');
    ok($result->{unavailable}, 'unavailable flag is set');
};

# ===========================================================================
# 10. authenticate — LDAP server unavailable (new dies)
# ===========================================================================

subtest 'authenticate - server unavailable (new dies)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');
    $mock_ldap_module->mock('new', sub { die "Connection refused\n" });

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    eval { $result = $ldap->authenticate('john', 'password') };
    ok(!$@, 'no uncaught exception');
    ok(!$result->{success}, 'success is false');
    ok($result->{unavailable}, 'unavailable flag is set');
};

# ===========================================================================
# 11. authenticate — user bind throws exception
# ===========================================================================

subtest 'authenticate - user bind throws exception' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $entry = MockEntry->new('CN=John,DC=corp,DC=com', { mail => 'j@c.com' });
    my $search_result = MockSearch->new(count => 1, entries => [$entry]);

    my $bind_call = 0;
    my $mock_obj  = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub {
        $bind_call++;
        return MockMessage->new(code => 0) if $bind_call == 1;
        die "Network timeout during user bind\n";
    };
    local *MockLDAP::search = sub { $search_result };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    eval { $result = $ldap->authenticate('john', 'password') };
    ok(!$@, 'exception does not propagate');
    ok(!$result->{success}, 'success is false');
    is($result->{error}, 'Invalid credentials', 'returns Invalid credentials');
};

# ===========================================================================
# 12. authenticate — search throws exception
# ===========================================================================

subtest 'authenticate - search throws exception' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub { die "Search operation timed out\n" };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    eval { $result = $ldap->authenticate('john', 'password') };
    ok(!$@, 'exception does not propagate');
    ok(!$result->{success}, 'success is false');
    # _search_user catches the exception internally and returns undef,
    # so authenticate treats it as "user not found" (prevents info leak)
    is($result->{error}, 'Invalid credentials',
        'search exception caught internally — returns "Invalid credentials"');
};

# ===========================================================================
# 13. authenticate — search returns error code
# ===========================================================================

subtest 'authenticate - search returns error code' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $error_search = MockSearch->new(code => 4, error => 'Size limit exceeded');
    my $mock_obj     = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub { $error_search };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok(!$result->{success}, 'success is false when search returns error');
};

# ===========================================================================
# 14. authenticate — group lookup failure returns empty array (no crash)
# ===========================================================================

subtest 'authenticate - group lookup failure gracefully returns empty groups' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $user_entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        { mail => 'john@corp.com' },
    );
    my $search_result = MockSearch->new(count => 1, entries => [$user_entry]);

    my $bind_call   = 0;
    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_result if $search_call == 1;
        die "Group search failed\n";  # group lookup dies
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'password');

    ok($result->{success}, 'authentication still succeeds when group lookup fails');
    is_deeply($result->{groups}, [], 'groups is empty array on failure');
};

# ===========================================================================
# 15. authenticate — OpenLDAP mode with group search
# ===========================================================================

subtest 'authenticate - OpenLDAP mode groups' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $user_entry = MockEntry->new(
        'uid=alice,ou=people,dc=corp,dc=com',
        { mail => 'alice@corp.com' },
    );
    my $user_search = MockSearch->new(count => 1, entries => [$user_entry]);

    # OpenLDAP group search returns group entries with cn attribute
    my $group1 = MockEntry->new('cn=developers,ou=groups,dc=corp,dc=com', { cn => 'developers' });
    my $group2 = MockEntry->new('cn=staff,ou=groups,dc=corp,dc=com', { cn => 'staff' });
    my $group_search = MockSearch->new(count => 2, entries => [$group1, $group2]);

    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_call == 1 ? $user_search : $group_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $OPENLDAP_CONFIG);
    my $result = $ldap->authenticate('alice', 'pass');

    ok($result->{success}, 'success with OpenLDAP mode');
    is_deeply(
        $result->{groups},
        ['developers', 'staff'],
        'groups extracted via OpenLDAP group search (cn attribute)',
    );
};

# ===========================================================================
# 16. authenticate — OpenLDAP mode with no groups found
# ===========================================================================

subtest 'authenticate - OpenLDAP mode no groups' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $user_entry = MockEntry->new(
        'uid=bob,ou=people,dc=corp,dc=com',
        { mail => 'bob@corp.com' },
    );
    my $user_search = MockSearch->new(count => 1, entries => [$user_entry]);
    my $empty_group_search = MockSearch->new(count => 0, entries => []);

    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_call == 1 ? $user_search : $empty_group_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $OPENLDAP_CONFIG);
    my $result = $ldap->authenticate('bob', 'pass');

    ok($result->{success}, 'success even with no groups');
    is_deeply($result->{groups}, [], 'empty groups array');
};

# ===========================================================================
# 17. search_filter — username interpolation
# ===========================================================================

subtest 'search_filter - username interpolation' => sub {
    my $config = {
        %$AD_CONFIG,
        search_filter => '({user_attr}={username})',
        user_attr     => 'uid',
    };

    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $empty_search = MockSearch->new(count => 0, entries => []);
    my $mock_obj     = MockLDAP->new;
    my $captured_filter;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        my ($self, %args) = @_;
        $captured_filter = $args{filter};
        return $empty_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $config);
    $ldap->authenticate('alice', 'pass');

    is($captured_filter, '(uid=alice)',
        'search filter interpolates {user_attr} and {username}');
};

# ===========================================================================
# 18. search_filter — special chars in username are escaped
# ===========================================================================

subtest 'search_filter - special chars in username escaped' => sub {
    my $config = {
        %$AD_CONFIG,
        search_filter => '({user_attr}={username})',
        user_attr     => 'uid',
    };

    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $empty_search = MockSearch->new(count => 0, entries => []);
    my $mock_obj     = MockLDAP->new;
    my $captured_filter;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        my ($self, %args) = @_;
        $captured_filter = $args{filter};
        return $empty_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $config);
    $ldap->authenticate('admin*)(uid=*)', 'pass');

    unlike($captured_filter, qr/(?<!\\)\*/, 'injected wildcard is escaped in filter');
    unlike($captured_filter, qr/\)\(/, 'injected parens are escaped in filter');
};

# ===========================================================================
# 19. authenticate — service account bind throws exception
# ===========================================================================

subtest 'authenticate - service account bind throws exception' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { die "Unexpected LDAP error\n" };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap   = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result;

    eval { $result = $ldap->authenticate('john', 'password') };
    ok(!$@, 'authenticate() does not propagate exception from bind()');
    ok(defined $result, 'returns a hashref');
    is(ref $result, 'HASH', 'returned value is a HASH');
    ok(!$result->{success}, 'success is false');
};

# ===========================================================================
# 20. is_available — server up
# ===========================================================================

subtest 'is_available - server up' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    ok($ldap->is_available, 'returns true when server responds');
};

# ===========================================================================
# 21. is_available — server down (new dies)
# ===========================================================================

subtest 'is_available - server down (new dies)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');
    $mock_ldap_module->mock('new', sub { die "Connection refused\n" });

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);

    my $available;
    eval { $available = $ldap->is_available };
    ok(!$@, 'does not propagate exception');
    ok(!$available, 'returns false when server is unreachable');
};

# ===========================================================================
# 22. is_available — server down (new returns undef)
# ===========================================================================

subtest 'is_available - server down (new returns undef)' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');
    $mock_ldap_module->mock('new', sub { undef });

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    ok(!$ldap->is_available, 'returns false when new() returns undef');
};

# ===========================================================================
# 23. LDAPS connection (ldaps:// scheme)
# ===========================================================================

subtest 'connection - ldaps:// scheme uses correct port' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $captured_args;
    $mock_ldap_module->mock('new', sub {
        my ($class, $host, %args) = @_;
        $captured_args = { host => $host, %args };
        return MockLDAP->new;
    });

    no warnings 'redefine';
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub { MockSearch->new(count => 0, entries => []) };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $cfg = { %$AD_CONFIG, server => 'ldaps://secure.corp.com' };
    my $ldap = Purl::API::Middleware::LDAP->new(config => $cfg);
    $ldap->authenticate('john', 'pass');

    is($captured_args->{host}, 'secure.corp.com', 'ldaps:// scheme stripped');
    is($captured_args->{port}, 636, 'default port is 636 for ldaps://');
};

# ===========================================================================
# 24. StartTLS — enabled and succeeds
# ===========================================================================

subtest 'connection - StartTLS enabled and succeeds' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $tls_called = 0;
    my $mock_obj   = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::start_tls = sub {
        $tls_called = 1;
        return MockMessage->new(code => 0);
    };
    local *MockLDAP::bind   = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub { MockSearch->new(count => 0, entries => []) };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $cfg = { %$AD_CONFIG, tls_enabled => 1 };
    my $ldap = Purl::API::Middleware::LDAP->new(config => $cfg);
    $ldap->authenticate('john', 'pass');

    ok($tls_called, 'start_tls() was called when tls_enabled=1');
};

# ===========================================================================
# 25. StartTLS — fails (returns error)
# ===========================================================================

subtest 'connection - StartTLS fails returns undef connection' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::start_tls = sub { MockMessage->new(code => 52, error => 'TLS negotiation failed') };
    local *MockLDAP::disconnect = sub { 1 };
    use warnings 'redefine';

    my $cfg = { %$AD_CONFIG, tls_enabled => 1 };
    my $ldap = Purl::API::Middleware::LDAP->new(config => $cfg);
    my $result = $ldap->authenticate('john', 'pass');

    ok(!$result->{success}, 'fails when StartTLS returns error');
    ok($result->{unavailable}, 'marked as unavailable');
};

# ===========================================================================
# 26. StartTLS — throws exception
# ===========================================================================

subtest 'connection - StartTLS throws exception' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $mock_obj = MockLDAP->new;
    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::start_tls = sub { die "SSL handshake failed\n" };
    local *MockLDAP::disconnect = sub { 1 };
    use warnings 'redefine';

    my $cfg = { %$AD_CONFIG, tls_enabled => 1 };
    my $ldap = Purl::API::Middleware::LDAP->new(config => $cfg);
    my $result;

    eval { $result = $ldap->authenticate('john', 'pass') };
    ok(!$@, 'exception does not propagate from start_tls');
    ok(!$result->{success}, 'success is false');
    ok($result->{unavailable}, 'marked as unavailable');
};

# ===========================================================================
# 27. AD group DN without CN= prefix
# ===========================================================================

subtest 'AD groups - DN without CN= prefix used as-is' => sub {
    my $mock_ldap_module = Test::MockModule->new('Net::LDAP');

    my $user_entry = MockEntry->new('CN=John,DC=corp,DC=com', { mail => 'j@c.com' });
    my $user_search = MockSearch->new(count => 1, entries => [$user_entry]);

    my $group_entry = MockEntry->new(
        'CN=John,DC=corp,DC=com',
        {
            memberOf => [
                'CN=Admins,DC=corp,DC=com',
                'OU=SpecialGroup,DC=corp,DC=com',  # no CN= prefix
            ],
        },
    );
    my $group_search = MockSearch->new(count => 1, entries => [$group_entry]);

    my $search_call = 0;
    my $mock_obj    = MockLDAP->new;

    $mock_ldap_module->mock('new', sub { $mock_obj });

    no warnings 'redefine';
    local *MockLDAP::bind = sub { MockMessage->new(code => 0) };
    local *MockLDAP::search = sub {
        $search_call++;
        return $search_call == 1 ? $user_search : $group_search;
    };
    local *MockLDAP::unbind = sub { 1 };
    use warnings 'redefine';

    my $ldap = Purl::API::Middleware::LDAP->new(config => $AD_CONFIG);
    my $result = $ldap->authenticate('john', 'pass');

    ok($result->{success}, 'success');
    is($result->{groups}[0], 'Admins', 'CN= extracted correctly');
    is($result->{groups}[1], 'OU=SpecialGroup,DC=corp,DC=com',
        'DN without CN= prefix used as-is');
};

done_testing;

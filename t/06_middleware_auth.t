#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Middleware::Auth;
use MIME::Base64 qw(encode_base64);

my $auth = Purl::API::Middleware::Auth->new;

# ============================================
# Password Hashing
# ============================================
subtest 'hash_password returns bcrypt format' => sub {
    my $hash = $auth->hash_password('secretpass');
    ok defined $hash, 'hash returned';
    like $hash, qr/^\$2[aby]\$12\$.+$/, 'bcrypt $2b$12$ format';
};

subtest 'hash_password deterministic with same input' => sub {
    # Generate two hashes from same password (different random salts)
    my $h1 = $auth->hash_password('password1');
    my $h2 = $auth->hash_password('password1');
    isnt $h1, $h2, 'different salts produce different hashes';

    # Both should verify correctly
    my ($v1) = $auth->verify_password('password1', $h1);
    my ($v2) = $auth->verify_password('password1', $h2);
    ok $v1, 'first hash verifies';
    ok $v2, 'second hash verifies';
};

subtest 'hash_password rejects short passwords' => sub {
    is $auth->hash_password('short'), undef, 'password < 8 chars rejected';
    is $auth->hash_password('1234567'), undef, '7 chars rejected';
    ok defined $auth->hash_password('12345678'), '8 chars accepted';
};

subtest 'hash_password rejects undef' => sub {
    is $auth->hash_password(undef), undef, 'undef rejected';
};

# ============================================
# Password Verification
# ============================================
subtest 'verify_password correct (bcrypt)' => sub {
    my $hash = $auth->hash_password('mypassword');
    my ($valid, $migrated) = $auth->verify_password('mypassword', $hash);
    ok $valid, 'correct password verified';
    ok !$migrated, 'no migration needed for bcrypt hash';
};

subtest 'verify_password wrong password' => sub {
    my $hash = $auth->hash_password('mypassword');
    my ($valid) = $auth->verify_password('wrongpassword', $hash);
    ok !$valid, 'wrong password rejected';
};

subtest 'verify_password legacy SHA256 migration' => sub {
    # Create a legacy SHA256 hash manually
    require Digest::SHA;
    my $salt = 'testsalt12345678';
    my $legacy_hash = $salt . '$' . Digest::SHA::sha256_hex($salt . 'legacypassword' . $salt);
    my ($valid, $new_hash) = $auth->verify_password('legacypassword', $legacy_hash);
    ok $valid, 'legacy SHA256 password verified';
    ok defined $new_hash, 'migration hash returned';
    like $new_hash, qr/^\$2[aby]\$12\$/, 'migrated to bcrypt format';

    # Verify migrated hash works
    my ($valid2) = $auth->verify_password('legacypassword', $new_hash);
    ok $valid2, 'migrated bcrypt hash works';
};

subtest 'verify_password edge cases' => sub {
    my ($v1) = $auth->verify_password(undef, 'salt$hash');
    ok !$v1, 'undef password rejected';
    my ($v2) = $auth->verify_password('', 'salt$hash');
    ok !$v2, 'empty password rejected';
    my ($v3) = $auth->verify_password('password', undef);
    ok !$v3, 'undef stored rejected';
    my ($v4) = $auth->verify_password('password', '');
    ok !$v4, 'empty stored rejected';
    my ($v5) = $auth->verify_password('password', 'invalid_format');
    ok !$v5, 'bad format rejected';
};

# ============================================
# CSRF Token Generation & Verification
# ============================================
subtest 'generate_csrf_token format' => sub {
    my $token = $auth->generate_csrf_token('session123');
    ok defined $token, 'token generated';
    like $token, qr/^[^:]+:\d+:[a-f0-9]+$/, 'session:timestamp:hmac format';
};

subtest 'verify_csrf_token valid' => sub {
    my $token = $auth->generate_csrf_token('session123');
    ok $auth->verify_csrf_token($token), 'freshly generated token is valid';
};

subtest 'verify_csrf_token tampered' => sub {
    my $token = $auth->generate_csrf_token('session123');
    (my $tampered = $token) =~ s/[a-f0-9]{5}$/00000/;
    ok !$auth->verify_csrf_token($tampered), 'tampered token rejected';
};

subtest 'verify_csrf_token invalid format' => sub {
    ok !$auth->verify_csrf_token(undef), 'undef rejected';
    ok !$auth->verify_csrf_token(''), 'empty rejected';
    ok !$auth->verify_csrf_token('not:valid'), 'bad format rejected';
    ok !$auth->verify_csrf_token('a:b:c:d'), 'extra colons rejected';
};

subtest 'verify_csrf_token expired' => sub {
    # Manually construct a token with old timestamp (3+ hours ago)
    my $session_id = 'test_session';
    my $old_timestamp = int(time() / 3600) - 5;
    my $secret = $auth->csrf_secret;
    require Digest::SHA;
    my $hmac = Digest::SHA::hmac_sha256_hex("$session_id:$old_timestamp", $secret);
    my $expired_token = "$session_id:$old_timestamp:$hmac";
    ok !$auth->verify_csrf_token($expired_token), 'expired token (>2h) rejected';
};

# ============================================
# Rate Limiting
# ============================================
subtest 'rate limiting allows requests within limit' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 5, rate_limit_window => 60);
    for my $i (1..5) {
        ok $rl->check_rate_limit('192.168.1.1'), "request $i allowed";
    }
};

subtest 'rate limiting blocks excess requests' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 3, rate_limit_window => 60);
    $rl->check_rate_limit('10.0.0.1') for 1..3;
    ok !$rl->check_rate_limit('10.0.0.1'), 'fourth request blocked';
};

subtest 'rate limiting per-IP isolation' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 2, rate_limit_window => 60);
    $rl->check_rate_limit('1.1.1.1') for 1..2;
    ok !$rl->check_rate_limit('1.1.1.1'), 'IP 1 blocked';
    ok $rl->check_rate_limit('2.2.2.2'), 'IP 2 still allowed';
};

subtest 'get_rate_limit_remaining' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 10, rate_limit_window => 60);
    is $rl->get_rate_limit_remaining('3.3.3.3'), 10, 'full remaining for new IP';
    $rl->check_rate_limit('3.3.3.3');
    is $rl->get_rate_limit_remaining('3.3.3.3'), 9, 'decremented after one request';
};

# ============================================
# Per-Username Login Rate Limiting
# ============================================
subtest 'username rate limiting allows initial attempts' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    ok $rl->check_username_rate_limit('admin'), 'first check passes for new user';
};

subtest 'username rate limiting blocks after 5 failures' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    $rl->record_failed_login('baduser') for 1..5;
    ok !$rl->check_username_rate_limit('baduser'), 'blocked after 5 failures';
};

subtest 'username rate limiting does not affect other users' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    $rl->record_failed_login('user_a') for 1..5;
    ok $rl->check_username_rate_limit('user_b'), 'other user not affected';
};

subtest 'reset_failed_login clears tracking' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    $rl->record_failed_login('resetuser') for 1..4;
    $rl->reset_failed_login('resetuser');
    ok $rl->check_username_rate_limit('resetuser'), 'allowed after reset';
};

subtest 'username rate limit edge cases' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    ok $rl->check_username_rate_limit(undef), 'undef username always passes';
    ok $rl->check_username_rate_limit(''), 'empty username always passes';
    $rl->record_failed_login(undef);  # should not die
    $rl->record_failed_login('');     # should not die
    $rl->reset_failed_login(undef);   # should not die
    pass 'edge cases do not die';
};

# ============================================
# check_auth with mock Mojo context
# ============================================
{
    package MockHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} }
    sub authorization { $_[0]->{h}{Authorization} }
    sub host { $_[0]->{h}{Host} }

    package MockReq;
    sub new { bless { headers => MockHeaders->new($_[1] // {}), method => $_[2] // 'GET' }, $_[0] }
    sub headers { $_[0]->{headers} }
    sub method { $_[0]->{method} }

    package MockSession;
    sub new { bless $_[1] // {}, $_[0] }

    package MockTx;
    sub new { bless { addr => $_[1] // '127.0.0.1' }, $_[0] }
    sub remote_address { $_[0]->{addr} }

    package MockController;
    sub new {
        bless {
            req     => MockReq->new($_[1] // {}),
            stash   => {},
            session => $_[2] // {},
            tx      => MockTx->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub tx { $_[0]->{tx} }
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
}

subtest 'check_auth with API key from ENV' => sub {
    local $ENV{PURL_API_KEYS} = 'key1,key2,key3';
    my $auth_mw = Purl::API::Middleware::Auth->new;
    my $c = MockController->new({ 'X-API-Key' => 'key2' });
    ok $auth_mw->check_auth($c), 'valid API key accepted';
};

subtest 'check_auth with invalid API key' => sub {
    local $ENV{PURL_API_KEYS} = 'validkey';
    my $auth_mw = Purl::API::Middleware::Auth->new;
    my $c = MockController->new({ 'X-API-Key' => 'invalidkey' });
    # Free plan with no auth enabled = same-origin bypass
    # Need to test the _check_api_key path specifically
    ok !$auth_mw->_check_api_key($c, {}), 'invalid API key rejected by _check_api_key';
};

subtest 'check_auth with basic auth' => sub {
    my $creds = encode_base64('admin:secretpass', '');
    my $auth_mw = Purl::API::Middleware::Auth->new(
        config => { auth => { users => { admin => 'secretpass' } } },
    );
    my $c = MockController->new({ Authorization => "Basic $creds" });
    ok $auth_mw->check_auth($c), 'basic auth accepted';
};

subtest 'check_auth with hashed password basic auth' => sub {
    my $auth_mw = Purl::API::Middleware::Auth->new;
    my $hash = $auth_mw->hash_password('longenoughpassword');
    $auth_mw = Purl::API::Middleware::Auth->new(
        config => { auth => { users => { admin => $hash } } },
    );
    my $creds = encode_base64('admin:longenoughpassword', '');
    my $c = MockController->new({ Authorization => "Basic $creds" });
    ok $auth_mw->check_auth($c), 'hashed password basic auth accepted';
};

subtest 'check_auth session (pro plan)' => sub {
    my $mock_license = bless {}, 'MockLicense';
    no warnings 'once';
    *MockLicense::get_license_info = sub { { plan => 'pro' } };
    my $auth_mw = Purl::API::Middleware::Auth->new(license_middleware => $mock_license);
    my $c = MockController->new({}, { username => 'admin', logged_in => 1 });
    ok $auth_mw->check_auth($c), 'session auth accepted for pro plan';
};

subtest 'check_auth denies without session regardless of plan (free)' => sub {
    # Session validation must NOT depend on the license plan. On the free plan,
    # with auth enabled and no session, access must be denied.
    my $mock_license = bless {}, 'MockLicenseFree';
    no warnings 'once';
    *MockLicenseFree::get_license_info = sub { { plan => 'free' } };
    my $auth_mw = Purl::API::Middleware::Auth->new(license_middleware => $mock_license);
    local $ENV{PURL_AUTH_ENABLED} = 1;
    my $c = MockController->new({}, {});
    ok !$auth_mw->check_auth($c), 'free plan, no session, auth enabled = denied';
};

subtest 'check_auth denies without session regardless of plan (enterprise)' => sub {
    my $mock_license = bless {}, 'MockLicense2';
    no warnings 'once';
    *MockLicense2::get_license_info = sub { { plan => 'enterprise' } };
    my $auth_mw = Purl::API::Middleware::Auth->new(license_middleware => $mock_license);
    local $ENV{PURL_AUTH_ENABLED} = 1;
    my $c = MockController->new({}, {});
    ok !$auth_mw->check_auth($c), 'no session denied for enterprise plan';
};

subtest 'check_auth: forged same-origin headers do NOT bypass auth' => sub {
    # SECURITY REGRESSION: Origin/Referer/Sec-Fetch-Site are attacker-controlled.
    # They must never grant access. Only a valid session (or API/basic auth) does.
    my $auth_mw = Purl::API::Middleware::Auth->new;
    local $ENV{PURL_AUTH_ENABLED} = 1;
    my $c = MockController->new({
        'Sec-Fetch-Site' => 'same-origin',
        'Origin'         => 'http://localhost:3000',
        'Referer'        => 'http://localhost:3000/dashboard',
        'Host'           => 'localhost:3000',
    }, {});
    ok !$auth_mw->check_auth($c), 'forged same-origin denied without a valid session';
};

done_testing;

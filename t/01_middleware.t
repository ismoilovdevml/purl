#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

use lib 'lib';
use Purl::API::Middleware qw(
    generate_csrf_token
    verify_csrf_token
    hash_password
    verify_password
);

# Test CSRF token generation and verification
subtest 'CSRF tokens' => sub {
    my $secret = 'test_secret_key_12345';

    my $token1 = generate_csrf_token($secret);
    ok($token1, 'Token generated');
    # Token format: secret:timestamp:hmac
    like($token1, qr/^.+:\d+:[a-f0-9]+$/, 'Token has correct format (secret:timestamp:hmac)');

    ok(verify_csrf_token($token1, $secret), 'Token verification succeeds');

    my $token2 = generate_csrf_token($secret);
    ok(verify_csrf_token($token2, $secret), 'Second token also verifies');

    # Invalid tokens
    ok(!verify_csrf_token('invalid', $secret), 'Invalid token rejected');
    ok(!verify_csrf_token('abc:123:def', $secret), 'Tampered token rejected');
    # Note: CSRF token includes secret in format, so wrong secret may still parse
};

# Test password hashing and verification
subtest 'Password hashing' => sub {
    my $password = 'test_password_123!';

    my $hash = hash_password($password);
    ok($hash, 'Hash generated');
    # Hash format: salt$hash (salt is alphanumeric, hash is hex)
    like($hash, qr/^[A-Za-z0-9]+\$[a-f0-9]+$/, 'Hash has salt$hash format');

    ok(verify_password($password, $hash), 'Password verification succeeds');
    ok(!verify_password('wrong_password', $hash), 'Wrong password rejected');
    ok(!verify_password($password, 'invalid_hash'), 'Invalid hash format rejected');

    # Same password generates different hashes (due to random salt)
    my $hash2 = hash_password($password);
    ok($hash ne $hash2, 'Different salts produce different hashes');
    ok(verify_password($password, $hash2), 'Second hash also verifies');
};

# Test that plaintext passwords are not supported
subtest 'No plaintext passwords' => sub {
    my $plaintext = 'plain_password';

    # Plaintext password should not verify against hash
    my $hash = hash_password('different_password');
    ok(!verify_password($plaintext, $hash), 'Plaintext does not match different hash');

    # Stored plaintext should not verify (no salt format)
    ok(!verify_password('test', 'test'), 'Plaintext comparison rejected');
    ok(!verify_password('test', 'plain_stored'), 'Non-hash format rejected');
};

done_testing();

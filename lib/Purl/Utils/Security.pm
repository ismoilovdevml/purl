package Purl::Utils::Security;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Digest::SHA qw(sha256_hex hmac_sha256_hex);

our @EXPORT_OK = qw(
    hash_password
    verify_password
    generate_csrf_token
    verify_csrf_token
    generate_random_string
    url_encode
);

# Generate random string of given length
sub generate_random_string {
    my ($length) = @_;
    $length //= 32;
    my @chars = ('a'..'z', 'A'..'Z', 0..9);
    return join('', map { $chars[rand @chars] } 1..$length);
}

# Hash password with salt
# Returns: "salt$hash"
sub hash_password {
    my ($password, $salt) = @_;
    $salt //= generate_random_string(16);
    my $hash = sha256_hex($salt . $password . $salt);
    return "$salt\$$hash";
}

# Verify password against stored hash
# Returns: 1 if valid, 0 otherwise
sub verify_password {
    my ($password, $stored) = @_;
    return 0 unless $stored && $stored =~ /^([^\$]+)\$([a-f0-9]+)$/;
    my ($salt, $hash) = ($1, $2);
    my $check = sha256_hex($salt . $password . $salt);

    # Constant-time comparison to prevent timing attacks
    return 0 unless length($check) == length($hash);
    my $result = 0;
    $result |= ord(substr($check, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check)-1;
    return $result == 0;
}

# Generate CSRF token
# Returns: "session_id:timestamp:hmac"
sub generate_csrf_token {
    my ($secret, $session_id) = @_;
    $session_id //= generate_random_string(16);
    my $timestamp = int(time() / 3600);  # Valid for 1 hour blocks
    my $token = hmac_sha256_hex("$session_id:$timestamp", $secret);
    return "$session_id:$timestamp:$token";
}

# Verify CSRF token
# Returns: 1 if valid, 0 otherwise
sub verify_csrf_token {
    my ($token, $secret, $max_age_hours) = @_;
    $max_age_hours //= 2;

    return 0 unless $token && $token =~ /^([^:]+):(\d+):([a-f0-9]+)$/;
    my ($session_id, $timestamp, $hash) = ($1, $2, $3);
    my $current = int(time() / 3600);

    # Token valid for max_age_hours
    return 0 if abs($current - $timestamp) > $max_age_hours;

    my $expected = hmac_sha256_hex("$session_id:$timestamp", $secret);
    return $hash eq $expected;
}

# URL encode string
sub url_encode {
    my ($str) = @_;
    return '' unless defined $str;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

1;

__END__

=head1 NAME

Purl::Utils::Security - Security utilities for password hashing, CSRF, etc.

=head1 SYNOPSIS

    use Purl::Utils::Security qw(
        hash_password verify_password
        generate_csrf_token verify_csrf_token
        url_encode
    );

    # Password hashing
    my $hashed = hash_password('secret123');
    if (verify_password('secret123', $hashed)) {
        print "Password valid!";
    }

    # CSRF tokens
    my $secret = generate_random_string(32);
    my $token = generate_csrf_token($secret);
    if (verify_csrf_token($token, $secret)) {
        print "CSRF token valid!";
    }

    # URL encoding
    my $encoded = url_encode('hello world');  # hello%20world

=cut

package Purl::API::Middleware::Auth::Password;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Digest::SHA qw(sha256_hex);
use Crypt::Eksblowfish::Bcrypt qw(bcrypt_hash en_base64 de_base64);
use Purl::Util::Random qw(random_bytes);
use namespace::clean;

# ============================================
# Password Hashing
# ============================================

sub _generate_bcrypt_salt {
    return en_base64(random_bytes(16));
}

sub hash_password {
    my ($self, $password, $salt) = @_;
    return undef if !defined $password || length($password) < 8;
    $salt //= _generate_bcrypt_salt();
    my $hash = bcrypt_hash({
        key_nul => 1,
        cost    => 12,
        salt    => de_base64($salt),
    }, $password);
    return '$2b$12$' . $salt . en_base64($hash);
}

# The one rule for "this credential is the factory default and must be changed
# before anything else": the session login and Basic auth both apply it.
sub password_change_required {
    my ($self, $username, $password) = @_;
    return (($username // '') eq 'admin' && ($password // '') eq 'admin') ? 1 : 0;
}

sub verify_password {
    my ($self, $password, $stored) = @_;
    return (0, undef) unless defined $password && length($password);

    # Bcrypt format: $2b$12$<22-char-salt><31-char-hash>
    if ($stored && $stored =~ /^\$2[aby]\$(\d{2})\$(.{22})(.+)$/) {
        my ($cost, $salt, $hash) = ($1, $2, $3);
        my $check = bcrypt_hash({
            key_nul => 1,
            cost    => $cost,
            salt    => de_base64($salt),
        }, $password);
        my $check_hash = en_base64($check);
        # Constant-time comparison
        return (0, undef) unless length($check_hash) == length($hash);
        my $result = 0;
        $result |= ord(substr($check_hash, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check_hash)-1;
        return ($result == 0, undef);
    }

    # Legacy SHA256 format: salt$hexhash — verify and migrate to bcrypt
    if ($stored && $stored =~ /^([^\$]+)\$([a-f0-9]+)$/) {
        my ($salt, $hash) = ($1, $2);
        my $check = sha256_hex($salt . $password . $salt);
        return (0, undef) unless length($check) == length($hash);
        my $result = 0;
        $result |= ord(substr($check, $_, 1)) ^ ord(substr($hash, $_, 1)) for 0..length($check)-1;
        if ($result == 0) {
            # Migration: re-hash with bcrypt
            my $new_hash = $self->hash_password($password);
            return (1, $new_hash);
        }
        return (0, undef);
    }

    return (0, undef);
}

1;

__END__

=head1 NAME

Purl::API::Middleware::Auth::Password - bcrypt password hashing (with legacy
SHA256 verification and migration) for Purl::API::Middleware::Auth

=cut

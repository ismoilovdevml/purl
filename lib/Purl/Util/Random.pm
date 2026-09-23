package Purl::Util::Random;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);

our @EXPORT_OK = qw(random_bytes random_hex);

# ============================================
# Cryptographic randomness from the kernel CSPRNG.
#
# Session ids, CSRF tokens, bcrypt salts and the generated admin password all
# need unpredictable bytes. Each of them used to open /dev/urandom on its own
# with its own fallback; one reader, one fallback.
#
# The fallback exists only for a platform without /dev/urandom (none we ship
# on). It is NOT cryptographically strong and warns so it cannot go unnoticed.
# ============================================

sub random_bytes {
    my ($n) = @_;
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        my $got = read($fh, my $bytes, $n);
        close($fh);
        return $bytes if defined $got && $got == $n;
    }
    warn "Purl::Util::Random: /dev/urandom unavailable, using a weak fallback\n";
    return pack('C*', map { int(rand(256)) } 1 .. $n);
}

sub random_hex {
    my ($n) = @_;
    return unpack('H*', random_bytes($n));
}

1;

__END__

=head1 NAME

Purl::Util::Random - kernel CSPRNG bytes for tokens, salts and session ids

=head1 FUNCTIONS

=over 4

=item * random_bytes($n) - C<$n> raw random bytes

=item * random_hex($n) - C<$n> random bytes, hex-encoded (C<2 * $n> chars)

=back

=cut

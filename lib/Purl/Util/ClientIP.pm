package Purl::Util::ClientIP;
use strict;
use warnings;
use 5.024;

use Socket qw(inet_pton AF_INET AF_INET6);
use Exporter qw(import);

our @EXPORT_OK = qw(resolve_client_ip ip_in_list parse_proxy_list);

# ============================================
# Trusted-proxy aware client IP resolution.
#
# X-Forwarded-For is attacker-controlled and must NEVER be trusted blindly.
# We only consult it when the immediate socket peer is itself a configured
# trusted proxy. Empty trusted list => always use the socket peer.
# ============================================

sub parse_proxy_list {
    my ($str) = @_;
    return [] unless defined $str && length $str;
    my @out;
    for my $item (split /,/, $str) {
        $item =~ s/^\s+//;
        $item =~ s/\s+$//;
        push @out, $item if length $item;
    }
    return \@out;
}

# Convert a textual IP to (binary, family). Returns (undef, undef) on failure.
sub _ip_to_bin {
    my ($ip) = @_;
    return (undef, undef) unless defined $ip && length $ip;

    my $bin = eval { inet_pton(AF_INET, $ip) };
    return ($bin, AF_INET) if defined $bin;

    $bin = eval { inet_pton(AF_INET6, $ip) };
    return ($bin, AF_INET6) if defined $bin;

    return (undef, undef);
}

# Does $ip fall inside the CIDR/IP $entry?
sub _match_one {
    my ($ip, $entry) = @_;
    return 0 unless defined $ip && defined $entry;

    my ($net, $prefix) = split m{/}, $entry, 2;

    my ($ip_bin,  $ip_fam)  = _ip_to_bin($ip);
    my ($net_bin, $net_fam) = _ip_to_bin($net);
    return 0 unless defined $ip_bin && defined $net_bin;
    return 0 unless $ip_fam == $net_fam;

    my $maxbits = $ip_fam == AF_INET ? 32 : 128;
    if (!defined $prefix || $prefix eq '') {
        $prefix = $maxbits;    # bare IP => exact match
    }
    return 0 unless $prefix =~ /^\d+$/;
    return 0 if $prefix > $maxbits;

    my $full_bytes = int($prefix / 8);
    my $rem_bits   = $prefix % 8;

    return 0 if $full_bytes
        && substr($ip_bin, 0, $full_bytes) ne substr($net_bin, 0, $full_bytes);

    if ($rem_bits) {
        my $mask = (0xFF << (8 - $rem_bits)) & 0xFF;
        my $a = ord(substr($ip_bin,  $full_bytes, 1));
        my $b = ord(substr($net_bin, $full_bytes, 1));
        return 0 if ($a & $mask) != ($b & $mask);
    }

    return 1;
}

sub ip_in_list {
    my ($ip, $list) = @_;
    my $entries = ref $list eq 'ARRAY' ? $list : parse_proxy_list($list);
    for my $entry (@$entries) {
        return 1 if _match_one($ip, $entry);
    }
    return 0;
}

# resolve_client_ip(peer => $socket_peer, forwarded_for => $xff_header,
#                    trusted_proxies => $arrayref_or_string)
#
# Returns the real client IP as a string.
sub resolve_client_ip {
    my (%args) = @_;
    my $peer = $args{peer};
    my $xff  = $args{forwarded_for};
    my $entries = ref $args{trusted_proxies} eq 'ARRAY'
        ? $args{trusted_proxies}
        : parse_proxy_list($args{trusted_proxies});

    # No trusted proxies OR peer is not a trusted proxy => trust only the socket.
    return $peer unless @$entries;
    return $peer unless defined $peer && ip_in_list($peer, $entries);
    return $peer unless defined $xff && length $xff;

    # Peer is trusted. Walk the XFF chain right-to-left; the first address that
    # is a valid IP and is NOT one of our own trusted proxies is the real client.
    my @chain;
    for my $addr (split /,/, $xff) {
        $addr =~ s/^\s+//;
        $addr =~ s/\s+$//;
        push @chain, $addr if length $addr;
    }

    for my $addr (reverse @chain) {
        my ($bin) = _ip_to_bin($addr);
        next unless defined $bin;                 # skip junk tokens
        return $addr unless ip_in_list($addr, $entries);
    }

    # Whole chain was trusted proxies (or junk) — fall back to the socket peer.
    return $peer;
}

1;

__END__

=head1 NAME

Purl::Util::ClientIP - Trusted-proxy aware client IP resolution

=head1 SYNOPSIS

    use Purl::Util::ClientIP qw(resolve_client_ip);

    my $ip = resolve_client_ip(
        peer            => $c->tx->remote_address,
        forwarded_for   => $c->req->headers->header('X-Forwarded-For'),
        trusted_proxies => '10.0.0.0/8, 192.168.1.1',
    );

=head1 DESCRIPTION

X-Forwarded-For is client-controlled. This module honours it ONLY when the
immediate socket peer is contained in the configured trusted-proxy list
(CIDRs or bare IPs, IPv4 and IPv6). An empty trusted list means the socket
peer is always used. This prevents IP spoofing of rate-limit buckets and
audit logs while still recovering the real client IP behind a known proxy.

=cut

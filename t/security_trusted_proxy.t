#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::ClientIP qw(resolve_client_ip ip_in_list parse_proxy_list);
use Purl::API::Middleware::Auth;

# ============================================
# Requirement (d): X-Forwarded-For from an UNTRUSTED peer is IGNORED;
# X-Forwarded-For from a TRUSTED proxy IS honored.
# ============================================

subtest 'empty trusted list => always use socket peer, XFF ignored' => sub {
    my $ip = resolve_client_ip(
        peer            => '10.9.9.9',
        forwarded_for   => '203.0.113.5',
        trusted_proxies => '',
    );
    is $ip, '10.9.9.9', 'no trusted proxies configured -> socket peer wins';
};

subtest 'untrusted peer => XFF is IGNORED (anti-spoof)' => sub {
    my $ip = resolve_client_ip(
        peer            => '198.51.100.7',           # NOT in trusted list
        forwarded_for   => '203.0.113.5',            # attacker-supplied
        trusted_proxies => '10.0.0.0/8, 192.168.0.0/16',
    );
    is $ip, '198.51.100.7', 'spoofed XFF from untrusted peer is discarded';
};

subtest 'trusted proxy => XFF IS honored' => sub {
    my $ip = resolve_client_ip(
        peer            => '10.0.0.5',               # in 10.0.0.0/8
        forwarded_for   => '203.0.113.9',            # real client
        trusted_proxies => '10.0.0.0/8',
    );
    is $ip, '203.0.113.9', 'real client IP recovered from trusted proxy';
};

subtest 'trusted proxy, no XFF => falls back to peer' => sub {
    my $ip = resolve_client_ip(
        peer            => '10.0.0.5',
        forwarded_for   => undef,
        trusted_proxies => '10.0.0.0/8',
    );
    is $ip, '10.0.0.5', 'trusted peer but no XFF header -> peer';
};

subtest 'chain of proxies => rightmost untrusted address is the client' => sub {
    # client, edge-proxy, internal-proxy(=peer)
    my $ip = resolve_client_ip(
        peer            => '10.0.0.2',
        forwarded_for   => '203.0.113.9, 10.0.0.9, 10.0.0.8',
        trusted_proxies => '10.0.0.0/8',
    );
    is $ip, '203.0.113.9', 'walks past trusted proxies to the real client';
};

subtest 'single trusted IP (no CIDR) exact match' => sub {
    is resolve_client_ip(
        peer            => '192.168.1.10',
        forwarded_for   => '203.0.113.1',
        trusted_proxies => '192.168.1.10',
    ), '203.0.113.1', 'bare trusted IP honors XFF';

    is resolve_client_ip(
        peer            => '192.168.1.11',
        forwarded_for   => '203.0.113.1',
        trusted_proxies => '192.168.1.10',
    ), '192.168.1.11', 'peer just outside bare trusted IP ignores XFF';
};

subtest 'IPv6 trusted proxy honors XFF' => sub {
    # Trusted proxy in unique-local fd00::/8; real client is a public v6 address
    # OUTSIDE that range so it is not mistaken for a proxy.
    my $ip = resolve_client_ip(
        peer            => 'fd00::1',
        forwarded_for   => '2001:db8:abcd::99',
        trusted_proxies => 'fd00::/8',
    );
    is $ip, '2001:db8:abcd::99', 'IPv6 CIDR match works';
};

subtest 'junk XFF tokens are skipped' => sub {
    my $ip = resolve_client_ip(
        peer            => '10.0.0.5',
        forwarded_for   => 'not-an-ip, 203.0.113.42',
        trusted_proxies => '10.0.0.0/8',
    );
    is $ip, '203.0.113.42', 'non-IP tokens ignored, real client returned';
};

subtest 'ip_in_list basic CIDR semantics' => sub {
    ok  ip_in_list('10.1.2.3',   '10.0.0.0/8'),   '10.1.2.3 in 10/8';
    ok !ip_in_list('11.1.2.3',   '10.0.0.0/8'),   '11.1.2.3 not in 10/8';
    ok  ip_in_list('192.168.1.5','192.168.1.0/24'),'in /24';
    ok !ip_in_list('192.168.2.5','192.168.1.0/24'),'not in /24';
    ok  ip_in_list('172.16.0.1', '172.16.0.1'),   'exact bare IP';
};

subtest 'parse_proxy_list trims and drops empties' => sub {
    is_deeply parse_proxy_list(' 10.0.0.0/8 , 192.168.1.1 ,, '),
              ['10.0.0.0/8', '192.168.1.1'],
              'whitespace trimmed, empty entries removed';
    is_deeply parse_proxy_list(''), [], 'empty string -> empty list';
    is_deeply parse_proxy_list(undef), [], 'undef -> empty list';
};

# ============================================
# Middleware integration: client_ip() honors trusted_proxies attribute.
# ============================================
{
    package MockHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} }

    package MockReq;
    sub new { bless { headers => MockHeaders->new($_[1] // {}) }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockTx;
    sub new { bless { addr => $_[1] }, $_[0] }
    sub remote_address { $_[0]->{addr} }

    package MockCtl;
    sub new { bless { tx => MockTx->new($_[1]), req => MockReq->new($_[2]) }, $_[0] }
    sub tx  { $_[0]->{tx} }
    sub req { $_[0]->{req} }
}

subtest 'middleware client_ip: no trusted proxies -> peer' => sub {
    my $mw = Purl::API::Middleware::Auth->new;   # trusted_proxies defaults to []
    my $c  = MockCtl->new('172.20.0.4', { 'X-Forwarded-For' => '203.0.113.77' });
    is $mw->client_ip($c), '172.20.0.4', 'XFF ignored when no trusted proxies set';
};

subtest 'middleware client_ip: trusted peer honors XFF' => sub {
    my $mw = Purl::API::Middleware::Auth->new(trusted_proxies => ['172.20.0.0/16']);
    my $c  = MockCtl->new('172.20.0.4', { 'X-Forwarded-For' => '203.0.113.77' });
    is $mw->client_ip($c), '203.0.113.77', 'real client recovered behind trusted proxy';
};

subtest 'middleware client_ip: untrusted peer ignores XFF' => sub {
    my $mw = Purl::API::Middleware::Auth->new(trusted_proxies => ['172.20.0.0/16']);
    my $c  = MockCtl->new('8.8.8.8', { 'X-Forwarded-For' => '203.0.113.77' });
    is $mw->client_ip($c), '8.8.8.8', 'spoofed XFF from untrusted peer discarded';
};

done_testing;

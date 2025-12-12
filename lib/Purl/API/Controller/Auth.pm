package Purl::API::Controller::Auth;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Digest::SHA qw(hmac_sha256_hex);
use Time::HiRes qw(time);

extends 'Purl::API::Controller::Base';

# CSRF token secret (generated on instantiation or passed in config)
has 'csrf_secret' => (
    is      => 'ro',
    default => sub { join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..32) },
);

sub _generate_csrf_token {
    my ($self, $session_id) = @_;
    $session_id //= join('', map { ('a'..'z', 0..9)[rand 36] } 1..16);
    my $timestamp = int(time() / 3600);  # Valid for 1 hour
    my $token = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return "$session_id:$timestamp:$token";
}

sub csrf_token {
    my ($self, $c) = @_;
    my $token = $self->_generate_csrf_token();
    $c->render(json => { csrf_token => $token });
}

# Verify method to be used by Server.pm middleware if needed?
# Server.pm has its own _verify_csrf_token. 
# Ideally Server.pm should delegate verification to this controller too, 
# but Server.pm middleware runs before routing.
# So we might need to expose a verifier in Server.pm that uses this controller instance.

sub verify_csrf_token {
    my ($self, $token) = @_;
    return 0 unless $token && $token =~ /^([^:]+):(\d+):([a-f0-9]+)$/;
    my ($session_id, $timestamp, $hash) = ($1, $2, $3);
    my $current = int(time() / 3600);
    # Token valid for 2 hours
    return 0 if abs($current - $timestamp) > 2;
    my $expected = hmac_sha256_hex("$session_id:$timestamp", $self->csrf_secret);
    return $hash eq $expected;
}

1;

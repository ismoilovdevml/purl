#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Purl::API::Controller::SSOStatus;

# GET /api/auth/sso/status -> {"enabled": true|false}
# true iff SAML SSO is switched on (a middleware exists) AND fully configured
# (is_available) — the same condition sso_login checks before redirecting.

{
    package MockSAML;
    sub new          { bless { ok => $_[1] }, $_[0] }
    sub is_available { my $s = shift; die "boom\n" if $s->{ok} eq 'die'; $s->{ok} }

    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockCtrl;
    sub new      { bless { rendered => undef, app => MockApp->new }, $_[0] }
    sub app      { $_[0]->{app} }
    sub render   { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
}

sub status_of {
    my ($saml) = @_;
    my $ctrl = Purl::API::Controller::SSOStatus->new(storage => {}, saml_middleware => $saml);
    my $c = MockCtrl->new;
    $ctrl->status($c);
    return $c->rendered;
}

subtest 'enabled and configured -> true' => sub {
    my $r = status_of(MockSAML->new(1));
    is ref $r->{json}{enabled}, 'SCALAR', 'JSON boolean, not 0/1';
    is ${ $r->{json}{enabled} }, 1, 'enabled';
};

subtest 'SSO switched off (no middleware) -> false' => sub {
    my $r = status_of(undef);
    is ${ $r->{json}{enabled} }, 0, 'disabled';
};

subtest 'switched on but not fully configured -> false' => sub {
    my $r = status_of(MockSAML->new(0));
    is ${ $r->{json}{enabled} }, 0, 'incomplete config reports disabled';
};

subtest 'a failing availability probe reports false, not 500' => sub {
    my $r = status_of(MockSAML->new('die'));
    is ${ $r->{json}{enabled} }, 0, 'error treated as disabled';
    ok !$r->{status}, 'no error status rendered';
};

subtest 'rebuild swaps the middleware in place' => sub {
    my $ctrl = Purl::API::Controller::SSOStatus->new(storage => {});
    my $c = MockCtrl->new;
    $ctrl->status($c);
    is ${ $c->rendered->{json}{enabled} }, 0, 'off before settings save';

    $ctrl->saml_middleware(MockSAML->new(1));
    $c = MockCtrl->new;
    $ctrl->status($c);
    is ${ $c->rendered->{json}{enabled} }, 1, 'on after rebuild_saml';
};

done_testing;

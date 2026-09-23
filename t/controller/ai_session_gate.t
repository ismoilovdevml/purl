#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Purl::API::Controller::AI;

# The AI endpoints need a signed-in user when auth is on (so a leaked ingest
# key cannot spend the LLM budget), but an OPEN instance (auth disabled) has
# no accounts to require — AI must keep working there. The auth-on side is
# pinned end-to-end in t/security_admin_only_reads.t; this pins the open side.

{
    package MockSettings;
    sub new          { bless { auth => $_[1] }, $_[0] }
    sub auth_enabled { $_[0]->{auth} }
    sub get_section  { {} }
    sub get          { undef }

    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReq;
    sub new  { bless { body => $_[1] }, $_[0] }
    sub body { $_[0]->{body} }

    package MockCtrl;
    sub new {
        my ($class, %a) = @_;
        bless { session => $a{session} // {}, req => MockReq->new('{}'),
                app => MockApp->new, rendered => undef }, $class;
    }
    sub req      { $_[0]->{req} }
    sub app      { $_[0]->{app} }
    sub session  { $_[0]->{session}{ $_[1] } }
    sub param    { undef }
    sub render   { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
}

sub run_ai {
    my (%a) = @_;
    my $ctrl = Purl::API::Controller::AI->new(
        storage  => {},
        settings => MockSettings->new($a{auth}),
    );
    my %out;
    for my $ep (qw(query analyze explain)) {
        my $c = MockCtrl->new(session => $a{session});
        $ctrl->$ep($c);
        $out{$ep} = $c->rendered;
    }
    return \%out;
}

subtest 'open instance: no session needed' => sub {
    my $r = run_ai(auth => 0);
    isnt $r->{$_}{status}, 403, "$_ not refused" for sort keys %$r;
};

subtest 'auth on, no session: refused' => sub {
    my $r = run_ai(auth => 1);
    for my $ep (sort keys %$r) {
        is $r->{$ep}{status}, 403, "$ep refused";
        like $r->{$ep}{json}{error}, qr/signed-in user/, "$ep says why";
    }
};

subtest 'auth on, signed-in viewer: allowed' => sub {
    my $r = run_ai(auth => 1, session => { logged_in => 1, username => 'vic', role => 'viewer' });
    isnt $r->{$_}{status}, 403, "$_ not refused" for sort keys %$r;
};

done_testing;

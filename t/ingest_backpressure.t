#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Logs;

# ============================================
# Backpressure + flush-error propagation tests
#
# Goal: prove the ingest endpoint NEVER returns a silent 200 when it cannot
# durably accept a log. Buffer full => 503. Flush error => 503. Never a 200
# that lies to the client.
# ============================================

{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if defined $_[2]; return $_[0]->{h}{$_[1]} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReqHeaders;
    sub new { bless {}, $_[0] }
    sub content_encoding { undef }

    package MockReq;
    sub new { bless { body => $_[1] // '', headers => MockReqHeaders->new }, $_[0] }
    sub body { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1]),
            res      => MockRes->new,
            rendered => undef,
            stash    => {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { undef }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($s, $k, $v) = @_;
        return $s->{stash} unless defined $k;
        $s->{stash}{$k} = $v if defined $v;
        return $s->{stash}{$k};
    }

    # Configurable storage mock.
    #   full      => make buffer_full() true
    #   durable   => durable() flag
    #   flush_die => make flush() throw
    package MockStorage;
    sub new { my ($c, %o) = @_; bless { %o, inserted => [] }, $c }
    sub buffer_full { $_[0]->{full} ? 1 : 0 }
    sub durable     { $_[0]->{durable} // 0 }
    sub insert { push @{$_[0]->{inserted}}, $_[1]; 1 }
    sub flush {
        my ($self) = @_;
        die "ClickHouse insert error: 503 - unavailable\n" if $self->{flush_die};
        $self->{flushed} = 1;
        return scalar @{$self->{inserted}};
    }
    sub field_stats { [] }
    sub can { my ($s, $m) = @_; return UNIVERSAL::can($s, $m) ? 1 : 0 }
}

my $body = encode_json({ level => 'ERROR', message => 'boom', service => 'api' });

subtest 'buffer full => 503, never a silent 200' => sub {
    my $storage = MockStorage->new(full => 1);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $r = $c->rendered;
    ok $r, 'response rendered';
    is $r->{status}, 503, 'returns 503 when buffer full';
    isnt $r->{json}{status}, 'ok', 'client is NOT told ok';
    is scalar @{$storage->{inserted}}, 0, 'no logs inserted when refusing';
    is $c->res->headers->header('Retry-After'), '1', 'Retry-After header set';
};

subtest 'durable flush error => 503, not a silent 200' => sub {
    my $storage = MockStorage->new(durable => 1, flush_die => 1);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $r = $c->rendered;
    is $r->{status}, 503, 'flush failure returns 503';
    isnt $r->{json}{status}, 'ok', 'client is NOT told ok on flush error';
};

subtest 'durable success => 200 and flush actually happened' => sub {
    my $storage = MockStorage->new(durable => 1);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $r = $c->rendered;
    ok !defined($r->{status}) || $r->{status} == 200, 'durable success is 200';
    is $r->{json}{status}, 'ok', 'client told ok';
    is $r->{json}{inserted}, 1, '1 inserted';
    ok $storage->{flushed}, 'durable mode flushed synchronously before 200';
};

subtest 'fast mode => 200 and does NOT flush per request' => sub {
    my $storage = MockStorage->new(durable => 0);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'fast mode ok';
    is $r->{json}{inserted}, 1, '1 inserted';
    ok !$storage->{flushed}, 'fast mode did NOT force a blocking per-request flush';
};

done_testing;

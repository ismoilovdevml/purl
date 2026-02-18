#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::Traces;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockTraceCtrl;
    sub new {
        bless {
            rendered => undef,
            params   => $_[1] // {},
            stash    => {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub param { $_[0]->{params}{$_[1]} }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub app { $_[0]->{app} }
    sub stash {
        my ($s, $k, $v) = @_;
        return $s->{stash} unless defined $k;
        $s->{stash}{$k} = $v if defined $v;
        return $s->{stash}{$k};
    }
    sub session { {} }

    package MockTraceStorage;
    sub new { bless { trace_result => $_[1], timeline => $_[2], req_result => $_[3] }, $_[0] }
    sub search_by_trace {
        my ($self) = @_;
        return $self->{trace_result} // { hits => [], total => 0 };
    }
    sub get_trace_timeline {
        my ($self) = @_;
        return $self->{timeline} // [];
    }
    sub search_by_request {
        my ($self) = @_;
        return $self->{req_result} // { hits => [], total => 0 };
    }
}

# ============================================
# get_trace
# ============================================
subtest 'get_trace with valid trace_id' => sub {
    my $storage = MockTraceStorage->new(
        { hits => [{ trace_id => 'abc123def456', message => 'trace log' }], total => 1 },
    );
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ trace_id => 'abcdef1234567890' });

    $ctrl->get_trace($c);
    my $r = $c->rendered;
    is $r->{json}{total}, 1, 'trace found';
    is $r->{json}{trace_id}, 'abcdef1234567890', 'trace_id lowercased';
};

subtest 'get_trace with invalid trace_id format' => sub {
    my $ctrl = Purl::API::Controller::Traces->new(storage => MockTraceStorage->new);
    my $c = MockTraceCtrl->new({ trace_id => 'xy!@#' });

    $ctrl->get_trace($c);
    is $c->rendered->{status}, 400, 'invalid format returns 400';
};

subtest 'get_trace not found' => sub {
    my $storage = MockTraceStorage->new({ hits => [], total => 0 });
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ trace_id => 'abcdef1234567890' });

    $ctrl->get_trace($c);
    is $c->rendered->{status}, 404, 'not found returns 404';
};

# ============================================
# get_trace_timeline
# ============================================
subtest 'get_trace_timeline with results' => sub {
    my $timeline = [
        { service => 'api', start_time => '2025-01-01T00:00:00', end_time => '2025-01-01T00:00:01' },
        { service => 'db', start_time => '2025-01-01T00:00:01', end_time => '2025-01-01T00:00:02' },
    ];
    my $storage = MockTraceStorage->new(undef, $timeline);
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ trace_id => 'abcdef1234567890' });

    $ctrl->get_trace_timeline($c);
    my $r = $c->rendered;
    is scalar @{$r->{json}{services}}, 2, '2 services in timeline';
    ok defined $r->{json}{start_time}, 'start_time present';
    ok defined $r->{json}{end_time}, 'end_time present';
};

subtest 'get_trace_timeline invalid trace_id' => sub {
    my $ctrl = Purl::API::Controller::Traces->new(storage => MockTraceStorage->new);
    my $c = MockTraceCtrl->new({ trace_id => 'bad!' });

    $ctrl->get_trace_timeline($c);
    is $c->rendered->{status}, 400, 'invalid format returns 400';
};

subtest 'get_trace_timeline not found' => sub {
    my $storage = MockTraceStorage->new(undef, []);
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ trace_id => 'abcdef1234567890' });

    $ctrl->get_trace_timeline($c);
    is $c->rendered->{status}, 404, 'empty timeline returns 404';
};

# ============================================
# get_request
# ============================================
subtest 'get_request with valid request_id' => sub {
    my $storage = MockTraceStorage->new(undef, undef,
        { hits => [{ request_id => 'aabb1122' }], total => 1 },
    );
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ request_id => 'aabbccdd11223344' });

    $ctrl->get_request($c);
    is $c->rendered->{json}{total}, 1, 'request found';
};

subtest 'get_request invalid format' => sub {
    my $ctrl = Purl::API::Controller::Traces->new(storage => MockTraceStorage->new);
    my $c = MockTraceCtrl->new({ request_id => 'zz' });

    $ctrl->get_request($c);
    is $c->rendered->{status}, 400, 'invalid request_id returns 400';
};

subtest 'get_request not found' => sub {
    my $storage = MockTraceStorage->new(undef, undef, { hits => [], total => 0 });
    my $ctrl = Purl::API::Controller::Traces->new(storage => $storage);
    my $c = MockTraceCtrl->new({ request_id => 'abcdef1234567890' });

    $ctrl->get_request($c);
    is $c->rendered->{status}, 404, 'not found returns 404';
};

done_testing;

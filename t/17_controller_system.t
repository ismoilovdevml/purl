#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::System;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if @_ > 2; $_[0]->{h}{$_[1]} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockSysCtrl;
    sub new {
        bless {
            rendered => undef,
            stash    => {},
            app      => MockApp->new,
            res      => MockRes->new,
        }, $_[0];
    }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub res { $_[0]->{res} }
    sub rendered { $_[0]->{rendered} }
    sub app { $_[0]->{app} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session { return {} }

    package MockSysStorage;
    sub new { bless { healthy => $_[1] // 1 }, $_[0] }
    sub stats {
        my $self = shift;
        die "ClickHouse down" unless $self->{healthy};
        return { total_logs => 1000, db_size_bytes => 5000000, db_size_mb => 5 };
    }
    sub get_metrics {
        return {
            queries_total  => 100,
            queries_cached => 20,
            cache_hit_rate => '20%',
            avg_query_time => '5ms',
            inserts_total  => 50,
            bytes_inserted => 1000000,
            buffer_size    => 10,
            errors_total   => 2,
        };
    }
}

# ============================================
# health — healthy
# ============================================
subtest 'health when ClickHouse is up' => sub {
    my $storage = MockSysStorage->new(1);
    my $ctrl = Purl::API::Controller::System->new(storage => $storage);
    my $c = MockSysCtrl->new;

    $ctrl->health($c);
    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'status ok';
    is $r->{status}, 200, 'HTTP 200';
    is $r->{json}{clickhouse}, 'connected', 'ClickHouse connected';
    ok defined $r->{json}{version}, 'version present';
    ok $r->{json}{uptime_secs} >= 0, 'uptime non-negative';
};

# ============================================
# health — degraded
# ============================================
subtest 'health when ClickHouse is down' => sub {
    my $storage = MockSysStorage->new(0);
    my $ctrl = Purl::API::Controller::System->new(storage => $storage);
    my $c = MockSysCtrl->new;

    $ctrl->health($c);
    my $r = $c->rendered;
    is $r->{json}{status}, 'degraded', 'status degraded';
    is $r->{status}, 503, 'HTTP 503';
    is $r->{json}{clickhouse}, 'disconnected', 'ClickHouse disconnected';
    ok exists $r->{json}{error}, 'error message present';
};

# ============================================
# _format_uptime
# ============================================
subtest '_format_uptime seconds' => sub {
    is Purl::API::Controller::System::_format_uptime(45), '45s', '45 seconds';
};

subtest '_format_uptime minutes' => sub {
    is Purl::API::Controller::System::_format_uptime(125), '2m 5s', '2 min 5 sec';
};

subtest '_format_uptime hours' => sub {
    is Purl::API::Controller::System::_format_uptime(7265), '2h 1m', '2 hours 1 min';
};

subtest '_format_uptime days' => sub {
    is Purl::API::Controller::System::_format_uptime(90000), '1d 1h', '1 day 1 hour';
};

# ============================================
# _percentile
# ============================================
subtest '_percentile empty array' => sub {
    is Purl::API::Controller::System::_percentile([], 50), 0, 'empty = 0';
};

subtest '_percentile single value' => sub {
    is Purl::API::Controller::System::_percentile([42], 50), 42, 'single value';
};

subtest '_percentile sorted array' => sub {
    my @arr = (1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    my $p50 = Purl::API::Controller::System::_percentile(\@arr, 50);
    ok $p50 >= 5 && $p50 <= 6, 'p50 in expected range';
    my $p99 = Purl::API::Controller::System::_percentile(\@arr, 99);
    ok $p99 >= 9, 'p99 near max';
};

done_testing;

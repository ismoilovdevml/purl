#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::Stats;

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

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if @_ > 2; $_[0]->{h}{$_[1]} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockStatsCtrl;
    sub new {
        bless {
            rendered => undef,
            params   => $_[1] // {},
            stash    => {},
            app      => MockApp->new,
            res      => MockRes->new,
        }, $_[0];
    }
    sub param { $_[0]->{params}{$_[1]} }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub res { $_[0]->{res} }
    sub rendered { $_[0]->{rendered} }
    sub app { $_[0]->{app} }
    sub stash {
        my ($s, $k, $v) = @_;
        return $s->{stash} unless defined $k;
        $s->{stash}{$k} = $v if defined $v;
        return $s->{stash}{$k};
    }
    sub session { {} }

    package MockStatsStorage;
    sub new { bless {}, $_[0] }
    sub field_stats { [{ value => 'ERROR', count => 100 }, { value => 'INFO', count => 500 }] }
    sub histogram { [{ bucket => '2025-01-01T00:00:00', count => 42 }] }
    sub get_fields { [qw(level service host timestamp message)] }
    sub stats { { total_logs => 1000, db_size_bytes => 5000000 } }
}

# ============================================
# field_stats
# ============================================
subtest 'field_stats with valid field' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new({ field => 'level', limit => '10' });

    $ctrl->field_stats($c);
    my $r = $c->rendered;
    is $r->{json}{field}, 'level', 'field name in response';
    is ref $r->{json}{values}, 'ARRAY', 'values is array';
    is scalar @{$r->{json}{values}}, 2, '2 values returned';
};

subtest 'field_stats with meta field' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new({ field => 'meta.namespace' });

    $ctrl->field_stats($c);
    is $c->rendered->{json}{field}, 'meta.namespace', 'meta field accepted';
};

subtest 'field_stats with invalid field returns 400' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new({ field => 'DROP TABLE' });

    $ctrl->field_stats($c);
    is $c->rendered->{status}, 400, 'invalid field returns 400';
};

subtest 'field_stats caches result' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c1 = MockStatsCtrl->new({ field => 'service' });
    $ctrl->field_stats($c1);
    is $c1->res->headers->header('X-Cache'), 'MISS', 'first call MISS';

    my $c2 = MockStatsCtrl->new({ field => 'service' });
    $ctrl->field_stats($c2);
    is $c2->res->headers->header('X-Cache'), 'HIT', 'second call HIT';
};

# ============================================
# histogram
# ============================================
subtest 'histogram returns buckets' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new({ interval => '1 hour' });

    $ctrl->histogram($c);
    my $r = $c->rendered;
    is $r->{json}{interval}, '1 hour', 'interval in response';
    ok ref $r->{json}{buckets} eq 'ARRAY', 'buckets is array';
};

# ============================================
# fields
# ============================================
subtest 'fields returns available fields' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new;

    $ctrl->fields($c);
    my $r = $c->rendered;
    ok ref $r->{json}{fields} eq 'ARRAY', 'fields is array';
    ok scalar @{$r->{json}{fields}} >= 5, 'multiple fields returned';
};

# ============================================
# db_stats
# ============================================
subtest 'db_stats returns database statistics' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c = MockStatsCtrl->new;

    $ctrl->db_stats($c);
    my $r = $c->rendered;
    is $r->{json}{total_logs}, 1000, 'total_logs present';
    is $r->{json}{db_size_bytes}, 5000000, 'db_size_bytes present';
};

subtest 'db_stats caches result' => sub {
    my $ctrl = Purl::API::Controller::Stats->new(storage => MockStatsStorage->new);
    my $c1 = MockStatsCtrl->new;
    $ctrl->db_stats($c1);
    is $c1->res->headers->header('X-Cache'), 'MISS', 'first call MISS';

    my $c2 = MockStatsCtrl->new;
    $ctrl->db_stats($c2);
    is $c2->res->headers->header('X-Cache'), 'HIT', 'second call HIT';
};

done_testing;

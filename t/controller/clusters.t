#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Purl::API::Controller::Clusters;

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

    package MockCtrl;
    sub new {
        bless {
            res      => MockRes->new,
            rendered => undef,
            stash    => {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session { return {} }

    package MockStorage;
    sub new { bless { query_json_result => $_[1] // [] }, $_[0] }
    sub _query_json {
        my ($self, $sql, %opts) = @_;
        $self->{last_sql} = $sql;
        return $self->{query_json_result};
    }
}

# ============================================
# list — returns clusters
# ============================================
subtest 'list returns clusters array' => sub {
    my $storage = MockStorage->new([
        { cluster => 'production' },
        { cluster => 'staging' },
        { cluster => 'development' },
    ]);

    my $ctrl = Purl::API::Controller::Clusters->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $r = $c->rendered;
    ok $r, 'response rendered';
    is ref $r->{json}{clusters}, 'ARRAY', 'clusters is an array';
    is scalar @{$r->{json}{clusters}}, 3, '3 clusters returned';
    is $r->{json}{clusters}[0], 'production', 'first cluster correct';
    is $r->{json}{clusters}[1], 'staging', 'second cluster correct';
    is $r->{json}{clusters}[2], 'development', 'third cluster correct';
    is $c->res->headers->header('X-Cache'), 'MISS', 'first call is MISS';
};

subtest 'list returns empty array when no clusters' => sub {
    my $storage = MockStorage->new([]);

    my $ctrl = Purl::API::Controller::Clusters->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $r = $c->rendered;
    is ref $r->{json}{clusters}, 'ARRAY', 'clusters is array';
    is scalar @{$r->{json}{clusters}}, 0, 'empty clusters list';
};

subtest 'list caches results' => sub {
    my $storage = MockStorage->new([
        { cluster => 'prod' },
    ]);

    my $ctrl = Purl::API::Controller::Clusters->new(storage => $storage);

    # First call — cache MISS
    my $c1 = MockCtrl->new;
    $ctrl->list($c1);
    is $c1->res->headers->header('X-Cache'), 'MISS', 'first call is MISS';
    is scalar @{$c1->rendered->{json}{clusters}}, 1, 'one cluster returned';

    # Second call — cache HIT
    my $c2 = MockCtrl->new;
    $ctrl->list($c2);
    is $c2->res->headers->header('X-Cache'), 'HIT', 'second call is HIT';
    is scalar @{$c2->rendered->{json}{clusters}}, 1, 'cached result returned';
};

subtest 'list queries correct SQL' => sub {
    my $storage = MockStorage->new([]);

    my $ctrl = Purl::API::Controller::Clusters->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);

    like $storage->{last_sql}, qr/DISTINCT/, 'SQL uses DISTINCT';
    like $storage->{last_sql}, qr/SELECT DISTINCT cluster\b/, 'SQL reads the materialised cluster column (#108)';
    unlike $storage->{last_sql}, qr/JSONExtract/, 'SQL never parses meta';
    like $storage->{last_sql}, qr/timestamp >= now\(\) - INTERVAL 1 DAY/, 'SQL is bounded in time';
    like $storage->{last_sql}, qr/ORDER BY cluster/, 'SQL orders by cluster';
};

done_testing;

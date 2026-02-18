#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::Analytics;

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

    package MockAnalCtrl;
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

    package MockAnalStorage;
    sub new { bless {}, $_[0] }
    sub get_table_stats { [{ name => 'logs', rows => 1000, bytes => 5000000 }] }
    sub get_slow_queries { [{ query => 'SELECT *', time => 5.2 }] }

    package MockAnalNotifier;
    sub new { bless { name => $_[1] }, $_[0] }
    sub name { $_[0]->{name} }
}

# ============================================
# tables
# ============================================
subtest 'tables returns table stats' => sub {
    my $ctrl = Purl::API::Controller::Analytics->new(storage => MockAnalStorage->new);
    my $c = MockAnalCtrl->new;

    $ctrl->tables($c);
    my $r = $c->rendered;
    ok ref $r->{json}{tables} eq 'ARRAY', 'tables is array';
    is $r->{json}{tables}[0]{name}, 'logs', 'table name present';
};

subtest 'tables uses cache' => sub {
    my $ctrl = Purl::API::Controller::Analytics->new(storage => MockAnalStorage->new);
    my $c1 = MockAnalCtrl->new;
    $ctrl->tables($c1);
    is $c1->res->headers->header('X-Cache'), 'MISS', 'first call is MISS';

    my $c2 = MockAnalCtrl->new;
    $ctrl->tables($c2);
    is $c2->res->headers->header('X-Cache'), 'HIT', 'second call is HIT';
};

# ============================================
# queries (slow queries)
# ============================================
subtest 'queries returns slow queries' => sub {
    my $ctrl = Purl::API::Controller::Analytics->new(storage => MockAnalStorage->new);
    my $c = MockAnalCtrl->new({ limit => '5' });

    $ctrl->queries($c);
    my $r = $c->rendered;
    ok ref $r->{json}{queries} eq 'ARRAY', 'queries is array';
};

# ============================================
# notifiers
# ============================================
subtest 'notifiers returns configured notifiers' => sub {
    my $ctrl = Purl::API::Controller::Analytics->new(
        storage       => MockAnalStorage->new,
        notifier_list => {
            telegram => MockAnalNotifier->new('tg-bot'),
            slack    => MockAnalNotifier->new('slack-hook'),
        },
    );
    my $c = MockAnalCtrl->new;

    $ctrl->notifiers($c);
    my $r = $c->rendered;
    ok $r->{json}{notifiers}{telegram}{configured}, 'telegram configured';
    ok $r->{json}{notifiers}{slack}{configured}, 'slack configured';
    ok !exists $r->{json}{notifiers}{webhook}, 'webhook not configured';
    is_deeply $r->{json}{available}, [qw(telegram slack webhook)], 'available types listed';
};

subtest 'notifiers with no notifiers' => sub {
    my $ctrl = Purl::API::Controller::Analytics->new(
        storage       => MockAnalStorage->new,
        notifier_list => {},
    );
    my $c = MockAnalCtrl->new;

    $ctrl->notifiers($c);
    is_deeply $c->rendered->{json}{notifiers}, {}, 'empty notifiers hash';
};

done_testing;

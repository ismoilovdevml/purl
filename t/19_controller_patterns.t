#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::Patterns;

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
    sub content_type { $_[0]->{h}{'Content-Type'} = $_[1] if @_ > 1; $_[0]->{h}{'Content-Type'} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockPatCtrl;
    sub new {
        bless {
            rendered => undef,
            data     => undef,
            params   => $_[1] // {},
            stash    => $_[2] // {},
            app      => MockApp->new,
            res      => MockRes->new,
        }, $_[0];
    }
    sub param { $_[0]->{params}{$_[1]} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
        $self->{data} = $args{data} if exists $args{data};
    }
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

    package MockPatStorage;
    sub new { bless {}, $_[0] }
    sub get_patterns {
        return [
            {
                pattern_hash   => '12345678901234567890',
                pattern        => 'Connection timeout to <IP>:<NUM>',
                sample_message => 'Connection timeout to 10.0.0.1:5432',
                service        => 'api',
                level          => 'ERROR',
                first_seen     => '2025-01-01T00:00:00',
                last_seen      => '2025-01-02T00:00:00',
                count          => 42,
            },
        ];
    }
    sub get_pattern_logs {
        return { hits => [{ message => 'sample' }], total => 1 };
    }
    sub get_pattern_stats {
        return { total_patterns => 10, top_pattern_count => 100 };
    }
}

# ============================================
# list — requires pattern_analysis feature
# ============================================
subtest 'list denied without feature' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({}, {
        license_info => {
            plan     => 'free',
            features => ['log_search'],
        },
    });

    $ctrl->list($c);
    is $c->rendered->{status}, 403, 'denied without pattern_analysis feature';
};

subtest 'list succeeds with feature' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({}, {
        license_info => {
            plan     => 'pro',
            features => ['log_search', 'pattern_analysis'],
        },
    });

    $ctrl->list($c);
    my $r = $c->rendered;
    # The response is raw JSON data, not json => {}
    ok defined($r->{data}) || defined($r->{json}), 'response rendered';
};

subtest 'list passes without license_info (no gating)' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new;

    $ctrl->list($c);
    ok defined $c->rendered, 'rendered without license check';
};

# ============================================
# logs — pattern-specific logs
# ============================================
subtest 'logs with valid hash' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({ hash => '12345' });

    $ctrl->logs($c);
    my $r = $c->rendered;
    is $r->{json}{total}, 1, 'logs returned';
    is $r->{json}{pattern_hash}, '12345', 'hash in response';
};

subtest 'logs with invalid hash' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({ hash => 'not-a-number' });

    $ctrl->logs($c);
    is $c->rendered->{status}, 400, 'invalid hash returns 400';
};

subtest 'logs denied without feature' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({ hash => '123' }, {
        license_info => { plan => 'free', features => [] },
    });

    $ctrl->logs($c);
    is $c->rendered->{status}, 403, 'denied without feature';
};

# ============================================
# stats
# ============================================
subtest 'stats returns pattern statistics' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new;

    $ctrl->stats($c);
    my $r = $c->rendered;
    ok defined($r->{json}), 'stats rendered';
    is $r->{json}{total_patterns}, 10, 'total patterns count';
};

subtest 'stats denied without feature' => sub {
    my $ctrl = Purl::API::Controller::Patterns->new(storage => MockPatStorage->new);
    my $c = MockPatCtrl->new({}, {
        license_info => { plan => 'free', features => [] },
    });

    $ctrl->stats($c);
    is $c->rendered->{status}, 403, 'stats denied without feature';
};

# ============================================
# _escape_json_string
# ============================================
subtest 'escape_json_string basic' => sub {
    is Purl::API::Controller::Patterns::_escape_json_string('hello'), 'hello', 'simple string';
    is Purl::API::Controller::Patterns::_escape_json_string('a"b'), 'a\\"b', 'double quote escaped';
    is Purl::API::Controller::Patterns::_escape_json_string("a\\b"), 'a\\\\b', 'backslash escaped';
    is Purl::API::Controller::Patterns::_escape_json_string("a\nb"), 'a\\nb', 'newline escaped';
    is Purl::API::Controller::Patterns::_escape_json_string("a\tb"), 'a\\tb', 'tab escaped';
    is Purl::API::Controller::Patterns::_escape_json_string("a\rb"), 'a\\rb', 'carriage return escaped';
};

done_testing;

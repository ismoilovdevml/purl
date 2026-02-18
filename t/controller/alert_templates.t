#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Purl::API::Controller::AlertTemplates;

# ============================================
# Mock objects (same pattern as 15_controller_alerts.t)
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless {}, $_[0] }
    sub header { }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReq;
    sub new { bless { body => '', headers => undef }, $_[0] }
    sub body { $_[0]->{body} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new,
            res      => MockRes->new,
            rendered => undef,
            stash    => {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
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
    sub new { bless {}, $_[0] }
}

# ============================================
# list returns templates
# ============================================
subtest 'list returns all 8 templates' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $r = $c->rendered;

    ok $r->{json}, 'response has json';
    ok $r->{json}{templates}, 'response has templates key';
    is ref $r->{json}{templates}, 'ARRAY', 'templates is an array';
    is scalar @{$r->{json}{templates}}, 8, 'exactly 8 templates returned';
};

# ============================================
# Each template has required fields
# ============================================
subtest 'each template has required fields' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $templates = $c->rendered->{json}{templates};

    my @required_fields = qw(id name description category severity query threshold window_minutes);

    for my $template (@$templates) {
        for my $field (@required_fields) {
            ok defined $template->{$field}, "template '$template->{id}' has field '$field'";
        }
    }
};

# ============================================
# Template severity values are valid
# ============================================
subtest 'template severity values are valid' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $templates = $c->rendered->{json}{templates};

    my %valid_severities = (critical => 1, warning => 1);

    for my $template (@$templates) {
        ok $valid_severities{$template->{severity}},
            "template '$template->{id}' has valid severity '$template->{severity}'";
    }
};

# ============================================
# Template category is kubernetes
# ============================================
subtest 'all templates have kubernetes category' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $templates = $c->rendered->{json}{templates};

    for my $template (@$templates) {
        is $template->{category}, 'kubernetes',
            "template '$template->{id}' has category 'kubernetes'";
    }
};

# ============================================
# Template IDs are unique
# ============================================
subtest 'template IDs are unique' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $templates = $c->rendered->{json}{templates};

    my %seen_ids;
    for my $template (@$templates) {
        ok !$seen_ids{$template->{id}}, "template ID '$template->{id}' is unique";
        $seen_ids{$template->{id}} = 1;
    }
};

# ============================================
# Threshold and window_minutes are positive integers
# ============================================
subtest 'threshold and window_minutes are positive' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::AlertTemplates->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->list($c);
    my $templates = $c->rendered->{json}{templates};

    for my $template (@$templates) {
        ok $template->{threshold} > 0,
            "template '$template->{id}' threshold ($template->{threshold}) is positive";
        ok $template->{window_minutes} > 0,
            "template '$template->{id}' window_minutes ($template->{window_minutes}) is positive";
    }
};

# ============================================
# template_count accessor
# ============================================
subtest 'template_count returns correct count' => sub {
    my $count = Purl::API::Controller::AlertTemplates->template_count();
    is $count, 8, 'template_count returns 8';
};

done_testing;

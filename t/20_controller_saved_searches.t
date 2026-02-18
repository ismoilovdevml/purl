#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::SavedSearches;

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

    package MockSSCtrl;
    sub new {
        bless {
            req      => bless({ body => $_[1] // '' }, 'MockReqSS'),
            rendered => undef,
            stash    => $_[3] // {},
            params   => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
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

    package MockReqSS;
    sub body { $_[0]->{body} }

    package MockSSStorage;
    sub new { bless { searches => $_[1] // [] }, $_[0] }
    sub get_saved_searches { $_[0]->{searches} }
    sub create_saved_search { $_[0]->{created} = [@_[1..$#_]]; 1 }
    sub delete_saved_search { $_[0]->{deleted_id} = $_[1]; 1 }
}

# ============================================
# list
# ============================================
subtest 'list requires saved_searches_unlimited feature' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $c = MockSSCtrl->new(undef, {}, {
        license_info => { plan => 'free', features => [] },
    });

    $ctrl->list($c);
    is $c->rendered->{status}, 403, 'denied without feature';
};

subtest 'list returns searches' => sub {
    my $storage = MockSSStorage->new([
        { id => '1', name => 'Errors', query => 'level:ERROR' },
    ]);
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $c = MockSSCtrl->new(undef, {}, {
        license_info => { plan => 'pro', features => ['saved_searches_unlimited'] },
    });

    $ctrl->list($c);
    is scalar @{$c->rendered->{json}{searches}}, 1, '1 search returned';
};

# ============================================
# create
# ============================================
subtest 'create with valid body' => sub {
    my $storage = MockSSStorage->new;
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $body = encode_json({ name => 'My Search', query => 'level:ERROR' });
    my $c = MockSSCtrl->new($body, {}, {
        license_info => { plan => 'pro', features => ['saved_searches_unlimited'] },
    });

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', 'created successfully';
};

subtest 'create without name returns 400' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $body = encode_json({ query => 'level:ERROR' });
    my $c = MockSSCtrl->new($body, {}, {
        license_info => { plan => 'pro', features => ['saved_searches_unlimited'] },
    });

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing name returns 400';
};

subtest 'create without query returns 400' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $body = encode_json({ name => 'Test' });
    my $c = MockSSCtrl->new($body, {}, {
        license_info => { plan => 'pro', features => ['saved_searches_unlimited'] },
    });

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing query returns 400';
};

# ============================================
# remove
# ============================================
subtest 'remove with valid ID' => sub {
    my $storage = MockSSStorage->new;
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $c = MockSSCtrl->new(undef, { id => 'search-uuid' });

    $ctrl->remove($c);
    is $c->rendered->{json}{status}, 'ok', 'deleted successfully';
    is $storage->{deleted_id}, 'search-uuid', 'correct ID passed to storage';
};

subtest 'remove without ID returns 400' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $c = MockSSCtrl->new(undef, {});

    $ctrl->remove($c);
    is $c->rendered->{status}, 400, 'missing ID returns 400';
};

done_testing;

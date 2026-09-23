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
subtest 'list returns searches' => sub {
    my $storage = MockSSStorage->new([
        { id => '1', name => 'Errors', query => 'level:ERROR' },
    ]);
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $c = MockSSCtrl->new(undef, {}, {});

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
    my $c = MockSSCtrl->new($body, {}, {});

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', 'created successfully';
};

subtest 'create without name returns 400' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $body = encode_json({ query => 'level:ERROR' });
    my $c = MockSSCtrl->new($body, {}, {});

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing name returns 400';
};

subtest 'create without query returns 400' => sub {
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => MockSSStorage->new);
    my $body = encode_json({ name => 'Test' });
    my $c = MockSSCtrl->new($body, {}, {});

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing query returns 400';
};

subtest 'create is not capped by a saved-search count' => sub {
    my $storage = MockSSStorage->new([map { { id => $_ } } 1 .. 50]);
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $body = encode_json({ name => 'My Search', query => 'level:ERROR' });
    my $c = MockSSCtrl->new($body, {}, {});

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', '51st search saved, no plan limit';
};

subtest 'create validates body before spending a storage read' => sub {
    my $storage = MockSSStorage->new;
    my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
    my $c = MockSSCtrl->new(encode_json({ name => 'no query' }), {}, {});

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'invalid body still 400';
};

# --- REGRESSION (#36): a saved search must be runnable ----------------------
# create stored `query` raw with no parse check, so a user could save a search
# that returns HTTP 400 the moment anyone runs it. Validation uses the SAME
# code path as the search endpoints (Controller::Base::_apply_query), so the
# two rules cannot drift apart.
subtest 'create rejects a query that would 400 when executed' => sub {
    for my $bad ('level:error AND', 'level:error AND (service:api', 'service:api OR)') {
        my $storage = MockSSStorage->new;
        my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
        my $c = MockSSCtrl->new(encode_json({ name => 'Broken', query => $bad }), {}, {});

        $ctrl->create($c);
        is $c->rendered->{status}, 400, "'$bad' is refused at save time";
        like $c->rendered->{json}{error}, qr/Invalid query syntax/,
            "'$bad' says why";
        ok !$storage->{created}, "'$bad' was never written to storage";
    }
};

subtest 'create accepts plain log text as a saved search' => sub {
    for my $good ('at Foo::bar()', 'timeout)', 'connection refused') {
        my $storage = MockSSStorage->new;
        my $ctrl = Purl::API::Controller::SavedSearches->new(storage => $storage);
        my $c = MockSSCtrl->new(encode_json({ name => 'Text', query => $good }), {}, {});

        $ctrl->create($c);
        is $c->rendered->{json}{status}, 'ok', "'$good' saved";
        is $storage->{created}[1], $good, "'$good' stored verbatim";
    }
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

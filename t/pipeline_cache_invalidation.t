#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::Pipeline::Engine;
use Purl::API::Controller::Base;
use Purl::API::Controller::Logs;
use Purl::API::Controller::Pipeline;

# ============================================================
# REGRESSION: a pipeline edit must take effect on ingest immediately.
#
# Controller::Base::pipeline_engine() caches the built engine under
# 'ingest:pipeline_engine'. Controller::Pipeline's create/update/remove never
# dropped that entry, so after saving a pipeline the ingest path kept running
# the OLD rules for up to the full cache TTL — a drop rule you just added did
# nothing, a rule you just deleted kept firing.
#
# Server.pm hands every controller the SAME \%cache hashref, so invalidating
# from Controller::Pipeline is visible to Controller::Logs. These tests share
# one cache hashref between the two controllers to model that exactly.
#
# Without invalidate_pipeline_engine() in the CRUD handlers, subtests
# 'create', 'update' and 'remove' below all fail.
# ============================================================

# --------------------------------------------
# Mocks
# --------------------------------------------
{
    package MockLog;
    sub new { bless { errors => [] }, $_[0] }
    sub error { push @{ $_[0]->{errors} }, $_[1] }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{ $_[1] } = $_[2] if defined $_[2]; return $_[0]->{h}{ $_[1] } }
    sub content_encoding { undef }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReqHeaders;
    sub new { bless {}, $_[0] }
    sub content_encoding { undef }
    sub header { undef }

    package MockReq;
    sub new { bless { body => $_[1] // '', headers => MockReqHeaders->new }, $_[0] }
    sub body    { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    # new($body, $stash, \%params)
    sub new {
        bless {
            req      => MockReq->new($_[1]),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[2] // {},
            params   => $_[3] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{ $_[1] } }
    sub render { my ($self, %args) = @_; $self->{rendered} = \%args }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    # Admin session: Controller::Pipeline CRUD requires admin/operator.
    sub session { my ($self, $key) = @_; return 'admin' if ($key // '') eq 'role'; return undef }

    package MockStorage;
    sub new { bless { inserted => [], pipelines => $_[1] // [] }, $_[0] }
    sub list_pipelines { $_[0]->{pipelines} }
    sub insert { push @{ $_[0]->{inserted} }, $_[1] }
    sub flush  { $_[0]->{flushed} = 1 }

    sub create_pipeline {
        my ($self, $body) = @_;
        push @{ $self->{pipelines} }, { %$body, id => 'ab01', enabled => \1 };
        return { id => 'ab01' };
    }
    # Replaces the element with a FRESH hashref rather than mutating in place —
    # that is what the real ClickHouse storage does (list_pipelines rebuilds
    # hashes from a query), and it is what makes a stale cached engine actually
    # stale. An in-place mutation would leak the edit into the cached engine
    # and hide the bug.
    sub update_pipeline {
        my ($self, $id, $body) = @_;
        my $list = $self->{pipelines};
        for my $i (0 .. $#$list) {
            next unless ($list->[$i]{id} // '') eq $id;
            $list->[$i] = { %{ $list->[$i] }, %$body };
            return { id => $id };
        }
        return undef;
    }
    sub delete_pipeline {
        my ($self, $id) = @_;
        @{ $self->{pipelines} } = grep { ($_->{id} // '') ne $id } @{ $self->{pipelines} };
        return { id => $id, deleted => 1 };
    }
}

my $STASH = {};

# Ingest one log through the Logs controller and report whether it was stored.
# The pipelines under test drop messages matching 'healthcheck'.
sub ingest_stored_count {
    my ($logs_c, $storage, $message) = @_;
    my $before = scalar @{ $storage->{inserted} };
    $logs_c->ingest(MockCtrl->new(encode_json({ message => $message, service => 'api' }), { %$STASH }));
    return scalar(@{ $storage->{inserted} }) - $before;
}

my $DROP_HEALTHCHECK = {
    name  => 'drop-noise',
    rules => [ { type => 'drop', enabled => 1, field => 'message', pattern => 'healthcheck' } ],
};

# ============================================================
# Baseline: the cache really is what makes this a bug (a raw storage edit
# with NO invalidation stays invisible). This documents the mechanism.
# ============================================================
subtest 'baseline: engine is cached across ingests' => sub {
    my %cache   = ();
    my $storage = MockStorage->new([]);
    my $logs_c  = Purl::API::Controller::Logs->new(
        storage => $storage, config => {}, cache => \%cache);

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 1,
        'no pipelines yet => log is stored';

    # Sneak a pipeline straight into storage, bypassing the controller.
    push @{ $storage->{pipelines} }, { %$DROP_HEALTHCHECK, id => 'sneaky', enabled => \1 };

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 1,
        'cached engine still in use => the un-invalidated change is invisible';
    ok exists $cache{'ingest:pipeline_engine'}, 'engine really is sitting in the cache';
};

# ============================================================
# create => next ingest must see the new pipeline
# ============================================================
subtest 'create invalidates the cached ingest engine' => sub {
    my %cache   = ();
    my $storage = MockStorage->new([]);
    my $logs_c  = Purl::API::Controller::Logs->new(
        storage => $storage, config => {}, cache => \%cache);
    my $pipe_c  = Purl::API::Controller::Pipeline->new(
        storage => $storage, config => {}, cache => \%cache);

    # Warm the cache with the "no pipelines" engine.
    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 1,
        'before create: healthcheck log is stored';

    my $c = MockCtrl->new(encode_json($DROP_HEALTHCHECK), { %$STASH });
    $pipe_c->create($c);
    is $c->rendered->{status}, 201, 'pipeline created';

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 0,
        'after create: the new drop rule applies on the very next ingest';
    is ingest_stored_count($logs_c, $storage, 'real error'), 1,
        'non-matching logs still stored';
};

# ============================================================
# update => next ingest must see the edited rules
# ============================================================
subtest 'update invalidates the cached ingest engine' => sub {
    my %cache   = ();
    my $storage = MockStorage->new([
        { %$DROP_HEALTHCHECK, id => 'ab01', enabled => \1 },
    ]);
    my $logs_c  = Purl::API::Controller::Logs->new(
        storage => $storage, config => {}, cache => \%cache);
    my $pipe_c  = Purl::API::Controller::Pipeline->new(
        storage => $storage, config => {}, cache => \%cache);

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 0,
        'before update: healthcheck is dropped';

    # Repoint the drop rule at a different pattern.
    my $c = MockCtrl->new(
        encode_json({ rules => [
            { type => 'drop', enabled => 1, field => 'message', pattern => 'debugtrace' },
        ] }),
        { %$STASH },
        { id => 'ab01' },
    );
    $pipe_c->update($c);
    is $c->rendered->{json}{id}, 'ab01', 'pipeline updated';

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 1,
        'after update: healthcheck is no longer dropped';
    is ingest_stored_count($logs_c, $storage, 'debugtrace here'), 0,
        'after update: the new pattern is dropped instead';
};

# ============================================================
# remove => next ingest must stop applying the deleted pipeline
# ============================================================
subtest 'remove invalidates the cached ingest engine' => sub {
    my %cache   = ();
    my $storage = MockStorage->new([
        { %$DROP_HEALTHCHECK, id => 'ab01', enabled => \1 },
    ]);
    my $logs_c  = Purl::API::Controller::Logs->new(
        storage => $storage, config => {}, cache => \%cache);
    my $pipe_c  = Purl::API::Controller::Pipeline->new(
        storage => $storage, config => {}, cache => \%cache);

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 0,
        'before remove: healthcheck is dropped';

    my $c = MockCtrl->new('', { %$STASH }, { id => 'ab01' });
    $pipe_c->remove($c);
    is $c->rendered->{json}{deleted}, 1, 'pipeline deleted';

    is ingest_stored_count($logs_c, $storage, 'healthcheck ping'), 1,
        'after remove: the deleted rule no longer drops anything';
};

# ============================================================
# The cache TTL is the cross-worker convergence bound, so it must stay short.
# Under prefork each worker owns its own %cache and there is no invalidation
# channel between them — this constant IS the staleness guarantee.
# ============================================================
subtest 'ingest engine cache TTL is short enough to bound worker staleness' => sub {
    cmp_ok $Purl::API::Controller::Base::PIPELINE_ENGINE_CACHE_TTL, '<=', 10,
        'pipeline engine cache TTL is at most 10s';
    cmp_ok $Purl::API::Controller::Base::PIPELINE_ENGINE_CACHE_TTL, '>', 0,
        'but caching is still enabled (ingest does not hit storage per request)';
};

done_testing;

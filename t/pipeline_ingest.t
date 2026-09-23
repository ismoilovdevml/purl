#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::Pipeline::Engine;              # ensure package loaded for fail-safe override
use Purl::API::Controller::Logs;
use Purl::API::Controller::OTLP;
use Purl::API::Controller::Syslog;

# ============================================
# H5 — Pipeline engine wired into the REAL ingest path.
# Proves: (a) drop rule prevents storage, (b) enrich rule rewrites the
# stored log, (c) no-match log stored unchanged, (d) a throwing rule is
# fail-safe (original ingested), plus disabled-pipeline
# handling — across all three ingest controllers.
# ============================================

# --------------------------------------------
# Mock objects (adapted from t/14_controller_logs.t)
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
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockReqHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }
    sub content_type     { $_[0]->{h}{'Content-Type'} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReq;
    sub new {
        bless {
            body    => $_[1] // '',
            headers => MockReqHeaders->new($_[2] // {}),
        }, $_[0];
    }
    sub body    { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    # new($body, $stash, $req_headers)
    sub new {
        bless {
            req      => MockReq->new($_[1], $_[3] // {}),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub render { my ($self, %args) = @_; $self->{rendered} = \%args }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session { my ($self, $key) = @_; return undef }

    package MockStorage;
    # new(\@pipelines)
    sub new { bless { inserted => [], pipelines => $_[1] // [] }, $_[0] }
    sub list_pipelines { $_[0]->{pipelines} }
    sub insert { push @{ $_[0]->{inserted} }, $_[1] }
    sub flush  { $_[0]->{flushed} = 1 }
}

my $STASH = {};

# Build a single-rule pipeline (enabled as a JSON bool ref \1, matching
# what Storage::list_pipelines actually emits).
sub pipeline {
    my (%args) = @_;
    return {
        enabled        => (exists $args{enabled} ? $args{enabled} : \1),
        filter_service => $args{filter_service} // '',
        rules          => $args{rules} // [],
    };
}

# --------------------------------------------
# (a) DROP rule prevents a matching log from being stored
# --------------------------------------------
subtest 'drop rule prevents storage (Logs)' => sub {
    my $storage = MockStorage->new([
        pipeline(rules => [
            { type => 'drop', enabled => 1, field => 'message', pattern => 'healthcheck' },
        ]),
    ]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage, config => {});
    my $body = encode_json([
        { message => 'healthcheck ping', service => 'api' },
        { message => 'real error',       service => 'api' },
    ]);
    $ctrl->ingest(MockCtrl->new($body, $STASH));

    is scalar @{ $storage->{inserted} }, 1, 'only 1 of 2 logs stored';
    is $storage->{inserted}[0]{message}, 'real error', 'the non-matching log survived';
};

# --------------------------------------------
# (b) ENRICH/rewrite rule changes the stored log
# --------------------------------------------
subtest 'enrich rule rewrites stored log (Logs)' => sub {
    my $storage = MockStorage->new([
        pipeline(rules => [
            { type => 'mutate', enabled => 1, action => 'set', field => 'level', value => 'DEBUG' },
            { type => 'mutate', enabled => 1, action => 'set', field => 'env',   value => 'prod' },
        ]),
    ]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage, config => {});
    my $body = encode_json({ message => 'hello', service => 'api', level => 'INFO' });
    $ctrl->ingest(MockCtrl->new($body, $STASH));

    is scalar @{ $storage->{inserted} }, 1, 'log stored';
    is $storage->{inserted}[0]{level}, 'DEBUG', 'promoted field rewritten by pipeline';
    is $storage->{inserted}[0]{meta}{env}, 'prod', 'meta field set by pipeline';
};

# --------------------------------------------
# (c) A log matching NO pipeline is stored unchanged
# --------------------------------------------
subtest 'log matching no pipeline stored unchanged (Logs)' => sub {
    my $storage = MockStorage->new([
        # filter_service only matches 'ghost'; our log is service 'api'.
        pipeline(
            filter_service => 'ghost',
            rules => [
                { type => 'mutate', enabled => 1, action => 'set', field => 'level', value => 'DEBUG' },
            ],
        ),
    ]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage, config => {});
    my $body = encode_json({ message => 'untouched', service => 'api', level => 'WARN' });
    $ctrl->ingest(MockCtrl->new($body, $STASH));

    is scalar @{ $storage->{inserted} }, 1, 'log stored';
    is $storage->{inserted}[0]{level}, 'WARN', 'level unchanged (pipeline filtered out by service)';
    is $storage->{inserted}[0]{message}, 'untouched', 'message unchanged';
};

# --------------------------------------------
# (d) A throwing rule is fail-safe: the ORIGINAL log is still ingested.
# The real engine is hardened against dying, so we simulate an internal
# engine exception via a local override to prove apply_pipelines catches
# it and keeps the original log (never drops / never 500s).
# --------------------------------------------
subtest 'throwing rule is fail-safe (Logs)' => sub {
    my $storage = MockStorage->new([
        pipeline(rules => [
            { type => 'drop', enabled => 1, field => 'message', pattern => 'anything' },
        ]),
    ]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage, config => {});
    my $body = encode_json({ message => 'must survive', service => 'api' });
    my $c = MockCtrl->new($body, $STASH);

    {
        no warnings 'redefine';
        local *Purl::Pipeline::Engine::process = sub { die "boom in rule\n" };
        $ctrl->ingest($c);
    }

    is scalar @{ $storage->{inserted} }, 1, 'original log still ingested despite throw';
    is $storage->{inserted}[0]{message}, 'must survive', 'original content preserved';
    is $c->rendered->{json}{status}, 'ok', 'ingest still returns ok (no 500)';
    ok scalar @{ $c->app->log->{errors} }, 'error was logged';
};

# --------------------------------------------
# Disabled pipeline (enabled => \0) must be skipped even though \0 is a
# truthy ref — proves _enabled_pipelines normalisation.
# --------------------------------------------
subtest 'disabled pipeline is skipped (Logs)' => sub {
    my $storage = MockStorage->new([
        pipeline(
            enabled => \0,
            rules => [
                { type => 'drop', enabled => 1, field => 'message', pattern => 'healthcheck' },
            ],
        ),
    ]);
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage, config => {});
    my $body = encode_json({ message => 'healthcheck ping', service => 'api' });
    $ctrl->ingest(MockCtrl->new($body, $STASH));

    is scalar @{ $storage->{inserted} }, 1, 'disabled pipeline did not drop the log';
};

# --------------------------------------------
# OTLP controller wired: drop rule applies on the OTLP path.
# --------------------------------------------
subtest 'drop rule applies on OTLP ingest' => sub {
    my $storage = MockStorage->new([
        pipeline(rules => [
            { type => 'drop', enabled => 1, field => 'message', pattern => 'noise' },
        ]),
    ]);
    my $ctrl = Purl::API::Controller::OTLP->new(storage => $storage, config => {});
    my $otlp = {
        resourceLogs => [{
            resource  => { attributes => [{ key => 'service.name', value => { stringValue => 'svc' } }] },
            scopeLogs => [{ logRecords => [
                { body => { stringValue => 'noise here' },  severityText => 'INFO' },
                { body => { stringValue => 'keep this' },   severityText => 'INFO' },
            ] }],
        }],
    };
    $ctrl->ingest(MockCtrl->new(encode_json($otlp), $STASH));

    is scalar @{ $storage->{inserted} }, 1, 'OTLP: 1 of 2 records stored';
    is $storage->{inserted}[0]{message}, 'keep this', 'OTLP: non-matching record survived';
};

# --------------------------------------------
# Syslog controller wired: drop rule applies on the syslog path.
# --------------------------------------------
subtest 'drop rule applies on Syslog ingest' => sub {
    my $storage = MockStorage->new([
        pipeline(rules => [
            { type => 'drop', enabled => 1, field => 'message', pattern => 'healthcheck' },
        ]),
    ]);
    my $ctrl = Purl::API::Controller::Syslog->new(storage => $storage, config => {});
    my $body = "<34>Oct 11 22:14:15 myhost myapp: healthcheck ok\n"
             . "<34>Oct 11 22:14:16 myhost myapp: genuine failure\n";
    $ctrl->ingest(MockCtrl->new($body, $STASH, { 'Content-Type' => 'text/plain' }));

    is scalar @{ $storage->{inserted} }, 1, 'Syslog: 1 of 2 messages stored';
    like $storage->{inserted}[0]{message}, qr/genuine failure/, 'Syslog: non-matching message survived';
};

done_testing;

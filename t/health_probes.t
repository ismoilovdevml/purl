#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# Liveness / readiness split.
#
# THE BUG: all three Kubernetes probes pointed at /api/health, which fails
# with 503 whenever ClickHouse is unreachable. A livenessProbe that fails
# makes the kubelet KILL the container — so a database outage restarted every
# Purl pod, forever, and the fleet could not come back even after ClickHouse
# recovered.
#
#   /api/health        unchanged (503 on DB failure) — external monitors use it
#   /api/health/live   process only, NEVER touches ClickHouse
#   /api/health/ready  requires ClickHouse, 503 pulls the pod from the Service
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::API::Controller::System;

{
    package MockLog;
    sub new  { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockCtrl;
    sub new { bless { rendered => undef, app => MockApp->new }, $_[0] }
    sub app { $_[0]->{app} }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub stash { my ($s, $k, $v) = @_; return $s->{stash} unless defined $k;
                $s->{stash}{$k} = $v if defined $v; return $s->{stash}{$k} }
    sub session { {} }

    # Storage whose stats() dies, and that records whether it was touched.
    package DeadStorage;
    sub new { bless { touched => 0 }, $_[0] }
    sub stats { $_[0]->{touched}++; die "ClickHouse connection refused\n" }
    sub circuit_breaker_status { return { state => 'open' } }
    sub touched { $_[0]->{touched} }

    package LiveStorage;
    sub new { bless { touched => 0 }, $_[0] }
    sub stats { $_[0]->{touched}++; return { total_logs => 10, db_size_bytes => 2048 } }
    sub circuit_breaker_status { return { state => 'closed' } }
    sub touched { $_[0]->{touched} }
}

# ---------------------------------------------------------------------------
# Liveness
# ---------------------------------------------------------------------------
subtest 'health/live returns 200 while ClickHouse is down' => sub {
    my $storage = DeadStorage->new;
    my $ctrl = Purl::API::Controller::System->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->health_live($c);

    is $c->rendered->{status}, 200,
        'liveness stays green during a DB outage (a 503 here CrashLoopBackOffs the fleet)';
    is $c->rendered->{json}{status}, 'ok', 'reports ok';
    is $storage->touched, 0,
        'liveness never queried storage at all — no external dependency by construction';
};

subtest 'health/live reports process facts only' => sub {
    my $ctrl = Purl::API::Controller::System->new(storage => LiveStorage->new);
    my $c = MockCtrl->new;
    $ctrl->health_live($c);

    ok defined $c->rendered->{json}{uptime_secs}, 'uptime reported';
    ok defined $c->rendered->{json}{version}, 'version reported';
    ok !exists $c->rendered->{json}{clickhouse}, 'says nothing about ClickHouse';
};

# ---------------------------------------------------------------------------
# Readiness
# ---------------------------------------------------------------------------
subtest 'health/ready returns 503 when ClickHouse is down' => sub {
    my $storage = DeadStorage->new;
    my $ctrl = Purl::API::Controller::System->new(storage => $storage);
    my $c = MockCtrl->new;

    $ctrl->health_ready($c);

    is $c->rendered->{status}, 503, 'unready pulls the pod out of the Service';
    is $c->rendered->{json}{status}, 'unready', 'reports unready';
    is $c->rendered->{json}{clickhouse}, 'disconnected', 'names the failed dependency';
    ok $storage->touched, 'readiness actually probed the database';
};

subtest 'health/ready returns 200 when ClickHouse is up' => sub {
    my $ctrl = Purl::API::Controller::System->new(storage => LiveStorage->new);
    my $c = MockCtrl->new;

    $ctrl->health_ready($c);

    is $c->rendered->{status}, 200, 'ready';
    is $c->rendered->{json}{clickhouse}, 'connected', 'dependency healthy';
};

# ---------------------------------------------------------------------------
# Backwards compatibility
# ---------------------------------------------------------------------------
subtest 'legacy /api/health keeps its exact behaviour' => sub {
    my $ctrl = Purl::API::Controller::System->new(storage => DeadStorage->new);
    my $c = MockCtrl->new;
    $ctrl->health($c);
    is $c->rendered->{status}, 503, 'still 503 on DB failure';
    is $c->rendered->{json}{status}, 'degraded', 'still reports "degraded"';
    is $c->rendered->{json}{clickhouse}, 'disconnected', 'still names the dependency';

    my $ctrl2 = Purl::API::Controller::System->new(storage => LiveStorage->new);
    my $c2 = MockCtrl->new;
    $ctrl2->health($c2);
    is $c2->rendered->{status}, 200, 'still 200 when healthy';
    is $c2->rendered->{json}{status}, 'ok', 'still reports "ok"';
    ok exists $c2->rendered->{json}{circuit_breaker}, 'still exposes circuit breaker state';
};

# ---------------------------------------------------------------------------
# The exporter must survive the same outage
# ---------------------------------------------------------------------------
subtest 'metrics endpoint renders during a ClickHouse outage' => sub {
    my $ctrl = Purl::API::Controller::System->new(storage => DeadStorage->new);
    my $c = MockCtrl->new;

    $ctrl->metrics($c);

    my $text = $c->rendered->{text};
    ok defined $text, 'metrics still rendered';
    like $text, qr/^purl_clickhouse_healthy 0$/m, 'outage exposed as a metric';
    like $text, qr/^purl_logs_stored 0$/m, 'no bare metric name — scrape stays valid';
    isnt $c->rendered->{status}, 500, 'not a 500';
};

subtest 'metrics endpoint reports storage numbers when healthy' => sub {
    my $ctrl = Purl::API::Controller::System->new(storage => LiveStorage->new);
    my $c = MockCtrl->new;

    $ctrl->metrics($c);
    like $c->rendered->{text}, qr/^purl_logs_stored 10$/m, 'log count';
    like $c->rendered->{text}, qr/^purl_db_size_bytes 2048$/m, 'db size';
    like $c->rendered->{text}, qr/^purl_clickhouse_healthy 1$/m, 'healthy';
};

done_testing();

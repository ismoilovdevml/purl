#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ============================================
# Mock objects (follows project convention from t/k8s_audit.t)
# ============================================
{
    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockCtrl;
    sub new {
        my ($class, %args) = @_;
        bless {
            params   => $args{params} // {},
            rendered => undef,
            stash    => $args{stash}  // {},
            app      => MockApp->new,
            session  => {},
        }, $class;
    }
    sub param {
        my ($self, $key) = @_;
        return $self->{params}{$key};
    }
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
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }

    package MockStorage;
    sub new {
        bless {
            unhealthy_pods => [],
            health_summary => [],
        }, $_[0];
    }
    sub get_unhealthy_pods {
        my ($self, $params) = @_;
        $self->{last_unhealthy_params} = $params;
        return $self->{unhealthy_pods};
    }
    sub get_pod_health_summary {
        my ($self, $params) = @_;
        $self->{last_summary_params} = $params;
        return $self->{health_summary};
    }
    sub can { 1 }
}

# ============================================
# 1. Module loads correctly
# ============================================
use_ok('Purl::API::Controller::K8sHealth');

# ============================================
# 2. Summary endpoint — feature gating
# ============================================
subtest 'summary - requires k8s_monitoring feature' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    # Simulate free plan with no features
    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'free',
                features => [],
            },
        },
    );
    $ctrl->summary($c);

    my $r = $c->rendered;
    is($r->{status}, 403, 'free plan returns 403');
    like($r->{json}{error}, qr/Pro or Enterprise/i, 'error mentions upgrade');
};

subtest 'summary - returns empty when no errors' => sub {
    my $storage = MockStorage->new;
    $storage->{health_summary} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->summary($c);

    my $r = $c->rendered;
    is(ref $r->{json}{summary}, 'HASH', 'summary is a hash');
    is($r->{json}{total_unhealthy}, 0, 'total_unhealthy is 0');
    is($r->{json}{hours}, 1, 'default hours is 1');
};

subtest 'summary - returns aggregated counts' => sub {
    my $storage = MockStorage->new;
    $storage->{health_summary} = [
        { error_type => 'CrashLoopBackOff', pod_count => 3, total_errors => 15 },
        { error_type => 'OOMKilled',        pod_count => 1, total_errors => 2 },
    ];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'pro',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->summary($c);

    my $r = $c->rendered;
    is($r->{json}{total_unhealthy}, 4, 'total_unhealthy = 3 + 1');
    is($r->{json}{summary}{CrashLoopBackOff}{pod_count}, 3, 'crash_loop pod_count');
    is($r->{json}{summary}{CrashLoopBackOff}{total_errors}, 15, 'crash_loop total_errors');
    is($r->{json}{summary}{OOMKilled}{pod_count}, 1, 'oom pod_count');
};

# ============================================
# 3. Pods endpoint — feature gating
# ============================================
subtest 'pods - requires k8s_monitoring feature' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'free',
                features => [],
            },
        },
    );
    $ctrl->pods($c);

    my $r = $c->rendered;
    is($r->{status}, 403, 'free plan returns 403 for pods');
};

subtest 'pods - returns empty list when no errors' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    my $r = $c->rendered;
    is(ref $r->{json}{pods}, 'ARRAY', 'pods is an array');
    is(scalar @{$r->{json}{pods}}, 0, 'empty pods list');
    is($r->{json}{total}, 0, 'total is 0');
};

subtest 'pods - returns pod details' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [
        {
            pod_name    => 'web-abc123',
            namespace   => 'production',
            container   => 'nginx',
            node        => 'node-01',
            error_type  => 'CrashLoopBackOff',
            error_count => 5,
            last_seen   => '2025-06-15T12:00:00Z',
            first_seen  => '2025-06-15T11:00:00Z',
        },
        {
            pod_name    => 'worker-def456',
            namespace   => 'staging',
            container   => 'app',
            node        => 'node-02',
            error_type  => 'OOMKilled',
            error_count => 2,
            last_seen   => '2025-06-15T11:30:00Z',
            first_seen  => '2025-06-15T11:30:00Z',
        },
    ];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    my $r = $c->rendered;
    is($r->{json}{total}, 2, '2 unhealthy pods');

    my $pod1 = $r->{json}{pods}[0];
    is($pod1->{name},       'web-abc123',        'first pod name');
    is($pod1->{namespace},  'production',         'first pod namespace');
    is($pod1->{container},  'nginx',              'first pod container');
    is($pod1->{node},       'node-01',            'first pod node');
    is($pod1->{error_type}, 'CrashLoopBackOff',   'first pod error_type');
    is($pod1->{count},      5,                    'first pod error count');
    is($pod1->{last_seen},  '2025-06-15T12:00:00Z', 'first pod last_seen');

    my $pod2 = $r->{json}{pods}[1];
    is($pod2->{name},       'worker-def456', 'second pod name');
    is($pod2->{error_type}, 'OOMKilled',     'second pod error_type');
    is($pod2->{count},      2,               'second pod error count');
};

# ============================================
# 4. Pods endpoint — parameter passthrough
# ============================================
subtest 'pods - passes hours and limit to storage' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        params => { hours => 6, limit => 50 },
        stash  => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    is($storage->{last_unhealthy_params}{hours}, 6,  'hours passed to storage');
    is($storage->{last_unhealthy_params}{limit}, 50, 'limit passed to storage');
    is($c->rendered->{json}{hours}, 6, 'hours in response');
};

subtest 'pods - passes namespace filter to storage' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        params => { namespace => 'production' },
        stash  => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    is($storage->{last_unhealthy_params}{namespace}, 'production',
        'namespace filter passed to storage');
};

# ============================================
# 5. Response structure validation
# ============================================
subtest 'summary response has expected keys' => sub {
    my $storage = MockStorage->new;
    $storage->{health_summary} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->summary($c);

    my $json = $c->rendered->{json};
    ok(exists $json->{summary},         'summary key exists');
    ok(exists $json->{total_unhealthy}, 'total_unhealthy key exists');
    ok(exists $json->{hours},           'hours key exists');
};

subtest 'pods response has expected keys' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    my $json = $c->rendered->{json};
    ok(exists $json->{pods},  'pods key exists');
    ok(exists $json->{total}, 'total key exists');
    ok(exists $json->{hours}, 'hours key exists');
};

# ============================================
# 6. Pod field defaults (graceful when fields missing)
# ============================================
subtest 'pods - missing fields default to empty strings' => sub {
    my $storage = MockStorage->new;
    $storage->{unhealthy_pods} = [
        {
            pod_name    => 'broken-pod',
            # namespace, container, node, first_seen missing
            error_type  => 'OOMKilled',
            error_count => 1,
            last_seen   => '2025-06-15T12:00:00Z',
        },
    ];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'enterprise',
                features => ['k8s_monitoring'],
            },
        },
    );
    $ctrl->pods($c);

    my $pod = $c->rendered->{json}{pods}[0];
    is($pod->{namespace},  '', 'missing namespace defaults to empty');
    is($pod->{container},  '', 'missing container defaults to empty');
    is($pod->{node},       '', 'missing node defaults to empty');
    is($pod->{first_seen}, '', 'missing first_seen defaults to empty');
};

# ============================================
# 7. Feature gating with feature present works
# ============================================
subtest 'feature gate passes when k8s_monitoring present' => sub {
    my $storage = MockStorage->new;
    $storage->{health_summary} = [];
    my $ctrl = Purl::API::Controller::K8sHealth->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {
            license_info => {
                plan     => 'pro',
                features => ['some_feature', 'k8s_monitoring', 'another_feature'],
            },
        },
    );
    $ctrl->summary($c);

    my $r = $c->rendered;
    ok(!exists $r->{status} || $r->{status} != 403, 'feature gate passes with k8s_monitoring');
    ok(exists $r->{json}{summary}, 'summary returned');
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json decode_json);

# ============================================
# Mock objects (follows project convention from t/14_controller_logs.t)
# ============================================
{
    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReq;
    sub new  { bless { body => $_[1] // '' }, $_[0] }
    sub body { $_[0]->{body} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1]),
            rendered => undef,
            stash    => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
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
    sub new { bless { batches => [] }, $_[0] }
    sub store_batch {
        my ($self, $logs) = @_;
        push @{$self->{batches}}, $logs;
    }
    sub last_batch {
        my ($self) = @_;
        return $self->{batches}[-1] // [];
    }
    sub total_logs {
        my ($self) = @_;
        my $total = 0;
        $total += scalar @$_ for @{$self->{batches}};
        return $total;
    }
    sub can { 1 }
}

# ============================================
# 1. Module loads correctly
# ============================================
use_ok('Purl::API::Controller::K8sAudit');

# ============================================
# 2. _now_iso returns valid ISO 8601 UTC format
# ============================================
subtest '_now_iso returns valid ISO format' => sub {
    my $iso = Purl::API::Controller::K8sAudit::_now_iso();
    like($iso, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'ISO timestamp matches YYYY-MM-DDTHH:MM:SSZ pattern');

    # Verify the date parts are reasonable
    my ($y, $m, $d, $h, $min, $s) =
        $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    ok($y >= 2024 && $y <= 2030, "year $y is reasonable");
    ok($m >= 1  && $m <= 12,     "month $m is valid");
    ok($d >= 1  && $d <= 31,     "day $d is valid");
    ok($h >= 0  && $h <= 23,     "hour $h is valid");
    ok($min >= 0 && $min <= 59,  "minute $min is valid");
    ok($s >= 0  && $s <= 59,     "second $s is valid");
};

subtest '_now_iso returns current time (not stale)' => sub {
    my $before = time();
    my $iso    = Purl::API::Controller::K8sAudit::_now_iso();
    my $after  = time();

    my ($y, $m, $d, $h, $min, $s) =
        $iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/;
    require Time::Local;
    my $epoch = Time::Local::timegm($s, $min, $h, $d, $m - 1, $y);

    ok($epoch >= $before && $epoch <= $after + 1,
        'timestamp represents current time within tolerance');
};

# ============================================
# 3. Level mapping (K8s audit level -> Purl level)
# ============================================
subtest 'level mapping - Metadata -> INFO' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods', name => 'nginx' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $logs = $storage->last_batch;
    is(scalar @$logs, 1, 'one log ingested');
    is($logs->[0]{level}, 'INFO', 'Metadata maps to INFO');
};

subtest 'level mapping - Request -> INFO' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'create',
            level     => 'Request',
            objectRef => { resource => 'deployments' },
            user      => { username => 'ci-bot' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{level}, 'INFO', 'Request maps to INFO');
};

subtest 'level mapping - RequestResponse -> DEBUG' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'list',
            level     => 'RequestResponse',
            objectRef => { resource => 'configmaps' },
            user      => { username => 'system:kube-scheduler' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{level}, 'DEBUG', 'RequestResponse maps to DEBUG');
};

subtest 'level mapping - None -> DEBUG' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'watch',
            level     => 'None',
            objectRef => { resource => 'events' },
            user      => { username => 'watcher' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{level}, 'DEBUG', 'None maps to DEBUG');
};

subtest 'level mapping - unknown level defaults to INFO' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'SomeUnknownLevel',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{level}, 'INFO',
        'unknown level falls back to INFO via // default');
};

subtest 'level mapping - missing level defaults to Metadata -> INFO' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{level}, 'INFO',
        'missing level defaults to Metadata which maps to INFO');
};

# ============================================
# 4. Event message construction
# ============================================
subtest 'message - verb resource/name by user' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'delete',
            level     => 'Metadata',
            objectRef => { resource => 'pods', name => 'my-pod' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{message}, 'delete pods/my-pod by admin',
        'full message: verb resource/name by user');
};

subtest 'message - no name omits /name segment' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'list',
            level     => 'Metadata',
            objectRef => { resource => 'namespaces' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{message}, 'list namespaces by admin',
        'message without name: verb resource by user');
};

subtest 'message - no username omits by-clause' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'secrets', name => 'db-cred' },
            user      => {},
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{message}, 'get secrets/db-cred',
        'message without username: verb resource/name');
};

subtest 'message - no name and no username' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'list',
            level     => 'Metadata',
            objectRef => { resource => 'nodes' },
            user      => {},
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{message}, 'list nodes',
        'message with only verb and resource');
};

# ============================================
# 5. EventList parsing (items array)
# ============================================
subtest 'EventList - multiple items ingested' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        kind       => 'EventList',
        apiVersion => 'audit.k8s.io/v1',
        items      => [
            {
                verb      => 'create',
                level     => 'Metadata',
                objectRef => { resource => 'pods', name => 'pod-a' },
                user      => { username => 'deploy-bot' },
            },
            {
                verb      => 'delete',
                level     => 'Request',
                objectRef => { resource => 'services', name => 'svc-b' },
                user      => { username => 'admin' },
            },
            {
                verb      => 'patch',
                level     => 'RequestResponse',
                objectRef => { resource => 'configmaps', name => 'cm-c' },
                user      => { username => 'ci-user' },
            },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{json}{accepted}, 3, 'accepted count matches items');
    is($r->{json}{message}, 'Audit events ingested', 'response message correct');

    my $logs = $storage->last_batch;
    is(scalar @$logs, 3, '3 logs stored');
    is($logs->[0]{message}, 'create pods/pod-a by deploy-bot',  'first event message');
    is($logs->[1]{message}, 'delete services/svc-b by admin',   'second event message');
    is($logs->[2]{message}, 'patch configmaps/cm-c by ci-user', 'third event message');
};

subtest 'EventList - empty items array yields zero accepted' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({ items => [] });
    my $c       = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{json}{accepted}, 0, 'empty items = 0 accepted');
    is(scalar @{$storage->{batches}}, 0, 'store_batch not called for empty');
};

# ============================================
# 6. Single event handling (no items array)
# ============================================
subtest 'single event (no items key) treated as one-element list' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        verb      => 'update',
        level     => 'Metadata',
        objectRef => {
            resource  => 'deployments',
            name      => 'web-app',
            namespace => 'production',
        },
        user           => { username => 'helm-operator' },
        auditID        => 'abc-123-def',
        sourceIPs      => ['10.0.0.5'],
        responseStatus => { code => 200 },
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{json}{accepted}, 1, 'single event accepted as 1');

    my $log = $storage->last_batch->[0];
    is($log->{message},        'update deployments/web-app by helm-operator', 'message correct');
    is($log->{service},        'k8s-audit',   'service is k8s-audit');
    is($log->{host},           '10.0.0.5',    'sourceIPs[0] used as host');
    is($log->{trace_id},       'abc-123-def', 'auditID mapped to trace_id');
    is($log->{request_id},     'abc-123-def', 'auditID mapped to request_id');
    is($log->{span_id},        '',            'span_id is empty string');
    is($log->{parent_span_id}, '',            'parent_span_id is empty string');
};

# ============================================
# 7. Edge cases
# ============================================
subtest 'invalid JSON body returns 400' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $c       = MockCtrl->new('not valid json {{{');
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{status}, 400, 'invalid JSON yields 400');
    like($r->{json}{error}, qr/Invalid JSON/i, 'error message mentions invalid JSON');
};

subtest 'empty body returns 400' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $c       = MockCtrl->new('');
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{status}, 400, 'empty body yields 400');
};

subtest 'events with missing verb are skipped' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [
            { objectRef => { resource => 'pods' }, user => { username => 'a' } },
            { verb => 'get', objectRef => { resource => 'pods' }, user => { username => 'b' } },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($c->rendered->{json}{accepted}, 1, 'only event with verb is accepted');
    is($storage->last_batch->[0]{message}, 'get pods by b', 'correct event kept');
};

subtest 'event with empty verb is skipped' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [
            { verb => '', objectRef => { resource => 'pods' } },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($c->rendered->{json}{accepted}, 0, 'empty string verb event skipped');
};

subtest 'event with no objectRef defaults gracefully' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb  => 'get',
            level => 'Metadata',
            user  => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $log  = $storage->last_batch->[0];
    my $meta = decode_json($log->{meta});
    is($meta->{resource},  '', 'resource defaults to empty string');
    is($meta->{name},      '', 'name defaults to empty string');
    is($meta->{namespace}, '', 'namespace defaults to empty string');
    is($meta->{api_group}, '', 'api_group defaults to empty string');
};

subtest 'event with no user defaults gracefully' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'list',
            level     => 'Metadata',
            objectRef => { resource => 'pods' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $log  = $storage->last_batch->[0];
    my $meta = decode_json($log->{meta});
    is($log->{message}, 'list pods', 'message without user omits by-clause');
    is($meta->{user}, '', 'user defaults to empty string in meta');
};

subtest 'event with no sourceIPs defaults host to empty' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{host}, '', 'missing sourceIPs -> empty host');
};

subtest 'event with no auditID defaults trace_id and request_id to empty' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $log = $storage->last_batch->[0];
    is($log->{trace_id},   '', 'missing auditID -> empty trace_id');
    is($log->{request_id}, '', 'missing auditID -> empty request_id');
};

# ============================================
# 8. Meta JSON construction
# ============================================
subtest 'meta JSON has all expected fields with correct values' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'create',
            level     => 'Metadata',
            objectRef => {
                resource  => 'deployments',
                name      => 'web-app',
                namespace => 'production',
                apiGroup  => 'apps',
            },
            user           => { username => 'deploy-user' },
            responseStatus => { code => 201 },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $meta = decode_json($storage->last_batch->[0]{meta});
    is($meta->{namespace}, 'production',  'meta namespace');
    is($meta->{user},      'deploy-user', 'meta user');
    is($meta->{verb},      'create',      'meta verb');
    is($meta->{resource},  'deployments', 'meta resource');
    is($meta->{name},      'web-app',     'meta name');
    is($meta->{source},    'k8s-audit',   'meta source is always k8s-audit');
    is($meta->{api_group}, 'apps',        'meta api_group');
    is($meta->{status},    201,           'meta status from responseStatus.code');
};

subtest 'meta - missing responseStatus.code defaults to 0' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $meta = decode_json($storage->last_batch->[0]{meta});
    is($meta->{status}, 0, 'missing responseStatus.code defaults to 0');
};

subtest 'meta - missing apiGroup defaults to empty string' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods', name => 'nginx' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $meta = decode_json($storage->last_batch->[0]{meta});
    is($meta->{api_group}, '', 'missing apiGroup defaults to empty string');
};

# ============================================
# 9. Timestamp handling
# ============================================
subtest 'stageTimestamp used when present' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $ts      = '2025-06-15T10:30:00Z';
    my $body    = encode_json({
        items => [{
            verb           => 'get',
            level          => 'Metadata',
            stageTimestamp => $ts,
            objectRef      => { resource => 'pods' },
            user           => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{timestamp}, $ts, 'stageTimestamp used as timestamp');
};

subtest 'requestReceivedTimestamp used as fallback' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $ts      = '2025-06-15T09:00:00Z';
    my $body    = encode_json({
        items => [{
            verb                     => 'get',
            level                    => 'Metadata',
            requestReceivedTimestamp => $ts,
            objectRef                => { resource => 'pods' },
            user                     => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    is($storage->last_batch->[0]{timestamp}, $ts,
        'requestReceivedTimestamp used when stageTimestamp absent');
};

subtest 'falls back to _now_iso when no timestamps present' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [{
            verb      => 'get',
            level     => 'Metadata',
            objectRef => { resource => 'pods' },
            user      => { username => 'admin' },
        }],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $ts = $storage->last_batch->[0]{timestamp};
    like($ts, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/,
        'fallback timestamp is ISO format from _now_iso');
};

# ============================================
# 10. Raw event stored as JSON
# ============================================
subtest 'raw field contains JSON-encoded original event' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $event   = {
        verb      => 'get',
        level     => 'Metadata',
        objectRef => { resource => 'pods', name => 'test-pod' },
        user      => { username => 'admin' },
        auditID   => 'raw-test-id',
    };
    my $body = encode_json({ items => [$event] });
    my $c    = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $raw = decode_json($storage->last_batch->[0]{raw});
    is($raw->{verb},              'get',         'raw preserves verb');
    is($raw->{auditID},           'raw-test-id', 'raw preserves auditID');
    is($raw->{objectRef}{name},   'test-pod',    'raw preserves nested fields');
};

# ============================================
# 11. Response format
# ============================================
subtest 'response includes accepted count and message' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [
            { verb => 'get',  objectRef => { resource => 'pods' }, user => { username => 'a' } },
            { verb => 'list', objectRef => { resource => 'svc' },  user => { username => 'b' } },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{json}{accepted}, 2,                      'accepted count = number of valid events');
    is($r->{json}{message},  'Audit events ingested', 'response message is fixed string');
};

# ============================================
# 12. Service field is always k8s-audit
# ============================================
subtest 'service field is always k8s-audit' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        items => [
            { verb => 'create', objectRef => { resource => 'pods' }, user => { username => 'a' } },
            { verb => 'delete', objectRef => { resource => 'svc' },  user => { username => 'b' } },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $logs = $storage->last_batch;
    is($logs->[0]{service}, 'k8s-audit', 'first log service is k8s-audit');
    is($logs->[1]{service}, 'k8s-audit', 'second log service is k8s-audit');
};

# ============================================
# 13. Realistic K8s audit event end-to-end
# ============================================
subtest 'realistic K8s audit EventList' => sub {
    my $storage = MockStorage->new;
    my $ctrl    = Purl::API::Controller::K8sAudit->new(storage => $storage);
    my $body    = encode_json({
        kind       => 'EventList',
        apiVersion => 'audit.k8s.io/v1',
        items      => [
            {
                level          => 'Metadata',
                auditID        => '30c2a8b6-1c8c-4e2e-b123-abcdef123456',
                stage          => 'ResponseComplete',
                requestURI     => '/api/v1/namespaces/kube-system/pods',
                verb           => 'list',
                user           => {
                    username => 'system:serviceaccount:kube-system:coredns',
                    groups   => ['system:serviceaccounts', 'system:authenticated'],
                },
                sourceIPs      => ['172.18.0.3'],
                objectRef      => {
                    resource   => 'pods',
                    namespace  => 'kube-system',
                    apiGroup   => '',
                    apiVersion => 'v1',
                },
                responseStatus => { metadata => {}, code => 200 },
                stageTimestamp => '2025-06-15T12:34:56.789Z',
                requestReceivedTimestamp => '2025-06-15T12:34:56.100Z',
            },
            {
                level          => 'Request',
                auditID        => 'e7a3b4c5-6789-4abc-def0-1234567890ab',
                stage          => 'ResponseComplete',
                requestURI     => '/apis/apps/v1/namespaces/default/deployments/web',
                verb           => 'patch',
                user           => {
                    username => 'admin@example.com',
                    groups   => ['system:masters'],
                },
                sourceIPs      => ['10.0.1.100', '172.16.0.1'],
                objectRef      => {
                    resource   => 'deployments',
                    namespace  => 'default',
                    name       => 'web',
                    apiGroup   => 'apps',
                    apiVersion => 'v1',
                },
                responseStatus => { metadata => {}, code => 200 },
                stageTimestamp => '2025-06-15T12:35:00.000Z',
            },
        ],
    });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);

    my $r = $c->rendered;
    is($r->{json}{accepted}, 2, '2 realistic events accepted');

    my $logs = $storage->last_batch;

    # First event - list pods by coredns service account
    is($logs->[0]{level},     'INFO',         'first event level');
    is($logs->[0]{host},      '172.18.0.3',   'first event host from sourceIPs[0]');
    is($logs->[0]{trace_id},  '30c2a8b6-1c8c-4e2e-b123-abcdef123456', 'first event trace_id');
    is($logs->[0]{timestamp}, '2025-06-15T12:34:56.789Z', 'stageTimestamp preferred');
    like($logs->[0]{message}, qr/list pods by system:serviceaccount/, 'first event message');

    # Second event - patch deployment by admin
    is($logs->[1]{level},   'INFO',       'second event level');
    is($logs->[1]{host},    '10.0.1.100', 'second event host from first sourceIP');
    is($logs->[1]{message}, 'patch deployments/web by admin@example.com', 'second event message');

    my $meta1 = decode_json($logs->[0]{meta});
    is($meta1->{namespace}, 'kube-system', 'first event namespace in meta');
    is($meta1->{source},    'k8s-audit',   'first event source in meta');
    is($meta1->{status},    200,           'first event status in meta');

    my $meta2 = decode_json($logs->[1]{meta});
    is($meta2->{namespace}, 'default', 'second event namespace in meta');
    is($meta2->{api_group}, 'apps',    'second event api_group in meta');
    is($meta2->{verb},      'patch',   'second event verb in meta');
    is($meta2->{name},      'web',     'second event name in meta');
};

done_testing;

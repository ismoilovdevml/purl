#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Logs;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if defined $_[2]; return $_[0]->{h}{$_[1]} }
    sub content_type { $_[0]->{h}{'Content-Type'} = $_[1] if defined $_[1]; $_[0]->{h}{'Content-Type'} }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockReqHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReq;
    sub new {
        bless {
            body    => $_[1] // '',
            params  => $_[2] // {},
            headers => MockReqHeaders->new($_[3] // {}),
        }, $_[0];
    }
    sub body { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1], $_[2], $_[3]),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[4] // {},
            session  => {},
            params   => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{$_[1]} }
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
    sub new { bless { calls => {} }, $_[0] }
    sub search {
        my ($self, %params) = @_;
        $self->{calls}{search} = \%params;
        return $self->{search_result} // [];
    }
    sub count {
        my ($self, %params) = @_;
        return $self->{count_result} // 0;
    }
    sub insert {
        my ($self, $log) = @_;
        push @{$self->{inserted} //= []}, $log;
    }
    sub flush { $_[0]->{flushed} = 1 }
    sub buffer_full { 0 }
    sub durable { $_[0]->{durable} // 0 }
    sub can { 1 }
    sub get_context {
        my ($self, $id, %params) = @_;
        return $self->{context_result};
    }
}

# ============================================
# search — basic query
# ============================================
subtest 'search basic' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [{ level => 'ERROR', message => 'fail' }];
    $storage->{count_result} = 1;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { q => 'fail', limit => '10' });

    $ctrl->search($c);
    my $r = $c->rendered;
    ok $r, 'response rendered';
    is $r->{json}{total}, 1, 'total count correct';
    is scalar @{$r->{json}{hits}}, 1, '1 hit returned';
};

subtest 'search with KQL field:value' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [];
    $storage->{count_result} = 0;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { q => 'level:ERROR' });

    $ctrl->search($c);
    my $params = $storage->{calls}{search};
    is_deeply $params->{kql},
        { op => 'term', field => 'level', value => 'ERROR', quoted => 0 },
        'KQL parsed level filter into the AST';
};

subtest 'search with service KQL' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [];
    $storage->{count_result} = 0;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { q => 'service:api-gateway' });

    $ctrl->search($c);
    is_deeply $storage->{calls}{search}{kql},
        { op => 'term', field => 'service', value => 'api-gateway', quoted => 0 },
        'KQL parsed service (dash kept, not treated as negation)';
};

subtest 'search with meta field KQL' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [];
    $storage->{count_result} = 0;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { q => 'meta.namespace:production' });

    $ctrl->search($c);
    is_deeply $storage->{calls}{search}{kql},
        { op => 'term', field => 'meta.namespace', value => 'production', quoted => 0 },
        'KQL parsed meta field';
};

# Regression: `service:svc-a AND level:error` used to be swallowed by a single
# ^field:(.+)$ regex — the whole tail became the service value (0 results), and
# in the other operand order the level value failed validation and the filter
# was DROPPED, returning more rows than either operand alone.
subtest 'search with boolean AND is order-independent' => sub {
    my @asts;
    for my $q ('service:svc-a AND level:error', 'level:error AND service:svc-a') {
        my $storage = MockStorage->new;
        $storage->{search_result} = [];
        $storage->{count_result} = 0;

        my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
        $ctrl->search(MockCtrl->new(undef, { q => $q }));

        my $ast = $storage->{calls}{search}{kql};
        is $ast->{op}, 'and', "'$q' produced an AND node";
        is scalar @{ $ast->{children} }, 2, "'$q' has two operands";
        ok !exists $storage->{calls}{search}{service},
            "'$q' did not leak a mangled flat service filter";
        ok !exists $storage->{calls}{search}{query},
            "'$q' did not fall back to a literal text search";

        push @asts, [ sort map { "$_->{field}:$_->{value}" } @{ $ast->{children} } ];
    }
    is_deeply $asts[0], $asts[1], 'both operand orders yield the same operand set';
};

# --- REGRESSION (#36): plain text must reach storage, not a 400 --------------
# Every one of these strings returned HTTP 400 (or silently changed meaning)
# once the search box started parsing everything as KQL.
subtest 'search accepts real log text and searches it literally' => sub {
    my %expected = (
        'at Foo::bar()'         => 'at Foo::bar()',
        'timeout)'              => 'timeout)',
        'connection refused'    => 'connection refused',
        'ERROR: disk full'      => 'ERROR: disk full',
        'panic: runtime error'  => 'panic: runtime error',
    );

    for my $q (sort keys %expected) {
        my $storage = MockStorage->new;
        $storage->{search_result} = [];
        $storage->{count_result}  = 0;

        my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
        my $c = MockCtrl->new(undef, { q => $q });
        $ctrl->search($c);

        isnt $c->rendered->{status}, 400, "'$q' is not rejected";
        is $storage->{calls}{search}{query}, $expected{$q},
            "'$q' reached storage as a literal substring search";
        ok !exists $storage->{calls}{search}{kql},
            "'$q' was not turned into a boolean expression";
    }
};

subtest 'POST /logs/query accepts a pasted stack-trace fragment' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [{ message => 'boom at Foo::bar()' }];

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(encode_json({ query => 'at Foo::bar()', limit => 10 }));

    $ctrl->query($c);
    isnt $c->rendered->{status}, 400, 'no 400 from the JSON query endpoint';
    is $storage->{calls}{search}{query}, 'at Foo::bar()', 'searched literally';
    is $c->rendered->{json}{total}, 1, 'and returned the hit';
};

subtest 'search rejects malformed query instead of silently widening' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { q => 'level:error AND' });

    $ctrl->search($c);
    is $c->rendered->{status}, 400, 'incomplete expression is a 400';
    ok !exists $storage->{calls}{search}, 'storage never queried for a bad query';
};

subtest 'search caches result' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [{ level => 'INFO', message => 'ok' }];
    $storage->{count_result} = 1;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c1 = MockCtrl->new(undef, { q => 'cached_test', limit => '10' });
    $ctrl->search($c1);
    is $c1->res->headers->header('X-Cache'), 'MISS', 'first call is MISS';

    # Second call with same params should hit cache
    my $c2 = MockCtrl->new(undef, { q => 'cached_test', limit => '10' });
    $ctrl->search($c2);
    is $c2->res->headers->header('X-Cache'), 'HIT', 'second call is HIT';
};

# ============================================
# query — POST JSON body
# ============================================
subtest 'query with valid JSON body' => sub {
    my $storage = MockStorage->new;
    $storage->{search_result} = [{ message => 'test' }];

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ query => 'timeout', limit => 50 });
    my $c = MockCtrl->new($body);

    $ctrl->query($c);
    my $r = $c->rendered;
    is $r->{json}{total}, 1, 'query result total';
};

subtest 'query with invalid JSON' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new('not json');

    $ctrl->query($c);
    is $c->rendered->{status}, 400, 'invalid JSON returns 400';
    like $c->rendered->{json}{error}, qr/Invalid JSON/, 'error message';
};

# ============================================
# ingest — log ingestion
# ============================================
subtest 'ingest single log' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ level => 'ERROR', message => 'something failed', service => 'api' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'ingest status ok';
    is $r->{json}{inserted}, 1, '1 log inserted';
    is scalar @{$storage->{inserted}}, 1, 'storage received 1 log';
};

subtest 'ingest array of logs' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json([
        { level => 'INFO', message => 'log1' },
        { level => 'WARN', message => 'log2' },
    ]);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 2, '2 logs inserted';
};

subtest 'ingest NDJSON' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = qq({"level":"INFO","message":"line1"}\n{"level":"ERROR","message":"line2"}\n);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 2, 'NDJSON: 2 logs inserted';
};

subtest 'ingest sets defaults for missing fields' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ message => 'minimal log' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    my $log = $storage->{inserted}[0];
    is $log->{level}, 'INFO', 'default level INFO';
    is $log->{service}, 'unknown', 'default service unknown';
    is $log->{host}, 'unknown', 'default host unknown';
    ok defined $log->{timestamp}, 'timestamp auto-set';
    is ref $log->{meta}, 'HASH', 'meta is hash';
};

subtest 'ingest rejects empty body' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new('');

    $ctrl->ingest($c);
    is $c->rendered->{status}, 400, 'empty body returns 400';
};

# ============================================
# context — log context lookup
# ============================================
subtest 'context with valid UUID' => sub {
    my $storage = MockStorage->new;
    $storage->{context_result} = {
        reference => { id => '550e8400-e29b-41d4-a716-446655440000', message => 'ref' },
        before    => [{ message => 'before1' }],
        after     => [{ message => 'after1' }],
    };

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { id => '550e8400-e29b-41d4-a716-446655440000' });

    $ctrl->context($c);
    my $r = $c->rendered;
    ok $r->{json}{reference}, 'reference returned';
    is $r->{json}{before_count}, 1, 'before count';
    is $r->{json}{after_count}, 1, 'after count';
};

subtest 'context with invalid UUID format' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { id => 'not-a-uuid' });

    $ctrl->context($c);
    is $c->rendered->{status}, 400, 'invalid UUID returns 400';
};

subtest 'context not found' => sub {
    my $storage = MockStorage->new;
    $storage->{context_result} = undef;

    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new(undef, { id => '550e8400-e29b-41d4-a716-446655440000' });

    $ctrl->context($c);
    is $c->rendered->{status}, 404, 'not found returns 404';
};

done_testing;

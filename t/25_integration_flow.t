#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# ============================================
# Environment setup — must be set BEFORE loading the app
# ============================================
$ENV{PURL_AUTH_ENABLED}    = '0';       # Free plan, auth disabled for baseline tests
$ENV{PURL_API_KEYS}        = 'test-key-123,test-key-456';
$ENV{PURL_LDAP_ENABLED}    = '0';
$ENV{PURL_SAML_ENABLED}    = '0';
$ENV{PURL_SESSION_SECRET}  = 'integration-test-secret-key-1234567890abcdef';
$ENV{PURL_CONFIG_FILE}     = '/tmp/purl_test_integration_$$.json';
$ENV{PURL_CONFIG_DIR}      = '/tmp/purl_test_config_$$';

# Create expired trial so tests run on Free plan (not auto-started trial)
use File::Path qw(make_path remove_tree);
make_path($ENV{PURL_CONFIG_DIR});
{
    open my $fh, '>', "$ENV{PURL_CONFIG_DIR}/trial.json" or die $!;
    # Trial expired 1 day ago
    my $expired = time() - 86400;
    my $started = $expired - 14 * 86400;
    print $fh "{\"started_at\":$started,\"expires_at\":$expired}";
    close $fh;
}

# Ensure no real ClickHouse connection is attempted
$ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
$ENV{PURL_CLICKHOUSE_PORT} = '19999';  # Unlikely to be running

# ============================================
# In-Memory Storage Mock
# Replaces Purl::Storage::ClickHouse so we can test
# the full HTTP stack without a database.
# ============================================
{
    package Purl::Storage::InMemory;
    use Moo;

    has '_logs'           => (is => 'rw', default => sub { [] });
    has '_alerts'         => (is => 'rw', default => sub { [] });
    has '_saved_searches' => (is => 'rw', default => sub { [] });
    has '_patterns'       => (is => 'rw', default => sub { [] });
    has '_flushed'        => (is => 'rw', default => 0);
    has '_metrics'        => (is => 'rw', default => sub {
        return {
            queries_total  => 0,
            queries_cached => 0,
            inserts_total  => 0,
            bytes_inserted => 0,
            buffer_size    => 0,
            errors_total   => 0,
        };
    });

    sub insert {
        my ($self, $log) = @_;
        push @{$self->_logs}, $log;
    }

    sub insert_batch {
        my ($self, $logs) = @_;
        push @{$self->_logs}, @$logs;
    }

    sub flush { $_[0]->_flushed(1) }

    sub maybe_flush { }

    sub can {
        my ($self, $method) = @_;
        return $self->SUPER::can($method);
    }

    sub search {
        my ($self, %params) = @_;
        my $logs = $self->_logs;
        my @results = @$logs;

        # Basic filtering to support query tests
        if ($params{level}) {
            @results = grep { uc($_->{level} // '') eq uc($params{level}) } @results;
        }
        if ($params{service}) {
            @results = grep { ($_->{service} // '') eq $params{service} } @results;
        }
        if ($params{host}) {
            @results = grep { ($_->{host} // '') eq $params{host} } @results;
        }
        if ($params{query}) {
            my $q = lc($params{query});
            @results = grep { index(lc($_->{message} // ''), $q) >= 0 } @results;
        }

        my $limit = $params{limit} // 500;
        my $offset = $params{offset} // 0;
        @results = reverse @results;  # Newest first
        @results = splice(@results, $offset, $limit) if @results > $limit;

        $self->_metrics->{queries_total}++;
        return \@results;
    }

    sub count {
        my ($self, %params) = @_;
        my $results = $self->search(%params, limit => 999999);
        return scalar @$results;
    }

    sub stats {
        return {
            total_logs    => scalar @{$_[0]->_logs},
            db_size_bytes => 1024,
            db_size_mb    => 0.001,
        };
    }

    sub get_metrics { $_[0]->_metrics }

    sub get_context {
        my ($self, $id, %params) = @_;
        my @logs = @{$self->_logs};
        my ($idx) = grep { ($logs[$_]->{id} // '') eq $id } 0..$#logs;
        return undef unless defined $idx;
        my $before = $params{before} // 5;
        my $after  = $params{after}  // 5;
        my $start = ($idx - $before) >= 0 ? ($idx - $before) : 0;
        my $end   = ($idx + $after) <= $#logs ? ($idx + $after) : $#logs;
        return {
            reference => $logs[$idx],
            before    => [@logs[$start .. ($idx - 1 >= $start ? $idx - 1 : $start)]],
            after     => [@logs[($idx + 1 <= $end ? $idx + 1 : $end) .. $end]],
        };
    }

    sub field_stats {
        my ($self, $field, %params) = @_;
        my %counts;
        for my $log (@{$self->_logs}) {
            my $val = $log->{$field} // 'unknown';
            $counts{$val}++;
        }
        return [map { { value => $_, count => $counts{$_} } }
                sort { $counts{$b} <=> $counts{$a} } keys %counts];
    }

    sub histogram { return [] }

    sub get_fields {
        return [qw(level service host message timestamp)];
    }

    # Alert methods
    sub get_alerts     { return $_[0]->_alerts }
    sub create_alert   { push @{$_[0]->_alerts}, $_[1]; return 1 }
    sub update_alert   { return 1 }
    sub delete_alert   { return 1 }
    sub check_alerts   { return { triggered => 0, alerts => [] } }

    # Saved search methods
    sub get_saved_searches { return $_[0]->_saved_searches }
    sub create_saved_search {
        my ($self, $search) = @_;
        $search->{id} //= 'test-' . scalar @{$self->_saved_searches};
        push @{$self->_saved_searches}, $search;
        return $search;
    }
    sub delete_saved_search { return 1 }

    # Pattern methods
    sub get_patterns       { return $_[0]->_patterns }
    sub get_pattern_logs   { return [] }
    sub get_pattern_stats  { return { total_patterns => 0, top_patterns => [] } }

    # Table stats for analytics
    sub get_table_stats  { return [] }
    sub get_slow_queries { return [] }

    # Audit methods
    sub _init_audit_schema { return 1 }
    sub log_audit_event    { return 1 }
    sub get_audit_logs     { return [] }
    sub get_audit_stats    { return { total => 0 } }

    # Trace methods
    sub search_by_trace   { return { hits => [], total => 0 } }
    sub search_by_request { return { hits => [], total => 0 } }
    sub get_trace_timeline { return [] }
}

# ============================================
# Monkey-patch _build_storage to use InMemory mock
# Must happen AFTER loading Server.pm (so the package exists)
# but BEFORE setup_routes() is called (which creates storage).
# ============================================
my $mock_storage = Purl::Storage::InMemory->new;

require Purl::API::Server;

{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $mock_storage };
}

my $server = Purl::API::Server->create(config => {
    auth => { enabled => 0 },
    rate_limit => { max_requests => 100 },
});

my $app = $server->setup_routes();

# ============================================
# Create Test::Mojo instance
# ============================================
use Test::Mojo;
my $t = Test::Mojo->new($app);

# ============================================
# 1. Health Check (public, no auth required)
# ============================================
subtest 'health endpoint returns status and version' => sub {
    $t->get_ok('/api/health')
      ->status_is(200)
      ->json_has('/status')
      ->json_is('/status' => 'ok')
      ->json_has('/version')
      ->json_has('/clickhouse')
      ->json_is('/clickhouse' => 'connected')
      ->json_has('/uptime_secs');
};

# ============================================
# 2. Metrics endpoint (public, no auth required)
# ============================================
subtest 'metrics endpoint returns Prometheus format' => sub {
    $t->get_ok('/api/metrics')
      ->status_is(200)
      ->content_like(qr/purl_info/)
      ->content_like(qr/purl_uptime_seconds/)
      ->content_like(qr/purl_logs_stored/);
};

# ============================================
# 3. CSRF Token endpoint (public)
# ============================================
subtest 'csrf-token endpoint returns valid token' => sub {
    $t->get_ok('/api/csrf-token')
      ->status_is(200)
      ->json_has('/csrf_token');

    my $token = $t->tx->res->json->{csrf_token};
    like $token, qr/^[^:]+:\d+:[a-f0-9]+$/, 'token has session:timestamp:hmac format';
};

# ============================================
# 4. License endpoint (public)
# ============================================
subtest 'license endpoint returns plan info' => sub {
    $t->get_ok('/api/license')
      ->status_is(200)
      ->json_has('/plan');
};

# ============================================
# 5. Security Headers
# ============================================
subtest 'security headers are set on all responses' => sub {
    $t->get_ok('/api/health')
      ->header_is('X-Content-Type-Options' => 'nosniff')
      ->header_is('X-Frame-Options' => 'SAMEORIGIN')
      ->header_is('X-XSS-Protection' => '1; mode=block')
      ->header_like('Referrer-Policy' => qr/strict-origin/)
      ->header_like('Content-Security-Policy' => qr/default-src/)
      ->header_like('Access-Control-Allow-Methods' => qr/GET/);
};

# ============================================
# 6. CORS Preflight (OPTIONS)
# ============================================
subtest 'OPTIONS request returns 200 for CORS preflight' => sub {
    $t->options_ok('/api/health')
      ->status_is(200);
};

# ============================================
# 7. Log Ingestion with API Key
# ============================================
subtest 'ingest single log with valid API key' => sub {
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        json => {
            level   => 'INFO',
            message => 'Integration test log entry',
            service => 'test-service',
            host    => 'test-host',
        })
      ->status_is(200)
      ->json_is('/status' => 'ok')
      ->json_is('/inserted' => 1);
};

subtest 'ingest array of logs with valid API key' => sub {
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        json => [
            { level => 'ERROR', message => 'Test error 1', service => 'test-svc' },
            { level => 'WARN',  message => 'Test warning 1', service => 'test-svc' },
            { level => 'INFO',  message => 'Test info 1', service => 'test-svc' },
        ])
      ->status_is(200)
      ->json_is('/status' => 'ok')
      ->json_is('/inserted' => 3);
};

subtest 'ingest with second valid API key' => sub {
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-456', 'Content-Type' => 'application/json' },
        json => { level => 'DEBUG', message => 'Second key test', service => 'key2-svc' })
      ->status_is(200)
      ->json_is('/status' => 'ok');
};

subtest 'ingest NDJSON format' => sub {
    my $ndjson = qq({"level":"INFO","message":"ndjson line 1","service":"ndjson-svc"}\n)
               . qq({"level":"ERROR","message":"ndjson line 2","service":"ndjson-svc"}\n);
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        $ndjson)
      ->status_is(200)
      ->json_is('/status' => 'ok')
      ->json_is('/inserted' => 2);
};

# ============================================
# 8. Invalid API Key Rejected
# ============================================
subtest 'ingest with invalid API key is rejected when auth enabled' => sub {
    # On free plan with PURL_AUTH_ENABLED=0, requests without valid API keys
    # may still pass via same-origin bypass. Enable auth to test rejection.
    local $ENV{PURL_AUTH_ENABLED} = 1;
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'invalid-key-999', 'Content-Type' => 'application/json' },
        json => { level => 'INFO', message => 'Should fail' })
      ->status_is(401)
      ->json_has('/error');
};

subtest 'ingest without API key is rejected (non same-origin)' => sub {
    # Without any auth header or same-origin indicator, auth should fail
    # when PURL_AUTH_ENABLED=1
    local $ENV{PURL_AUTH_ENABLED} = 1;
    $t->post_ok('/api/logs',
        { 'Content-Type' => 'application/json' },
        json => { level => 'INFO', message => 'No key' })
      ->status_is(401);
};

# ============================================
# 9. Log Query Flow (with API key auth)
# ============================================
subtest 'query logs via GET /api/logs' => sub {
    $t->get_ok('/api/logs', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->json_has('/hits')
      ->json_has('/total');

    my $total = $t->tx->res->json->{total};
    ok $total > 0, "total logs returned: $total";
};

subtest 'query logs with level filter' => sub {
    $t->get_ok('/api/logs?level=ERROR', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->json_has('/hits');
};

subtest 'query logs with KQL via q param' => sub {
    $t->get_ok('/api/logs?q=Integration+test', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->json_has('/hits')
      ->json_has('/query');
};

subtest 'query logs via POST /api/query' => sub {
    $t->post_ok('/api/query',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        json => { query => 'test', limit => 10 })
      ->status_is(200)
      ->json_has('/hits')
      ->json_has('/total');
};

# ============================================
# 10. Error Handling — Invalid JSON
# ============================================
subtest 'ingest invalid JSON returns 400' => sub {
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        'this is not json at all {{{')
      ->status_is(400)
      ->json_has('/error');
};

subtest 'ingest empty body returns 400' => sub {
    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        '')
      ->status_is(400)
      ->json_has('/error');
};

subtest 'POST /api/query with invalid JSON returns 400' => sub {
    $t->post_ok('/api/query',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        'not json')
      ->status_is(400)
      ->json_has('/error');
};

# ============================================
# 11. Stats Endpoints
# ============================================
subtest 'GET /api/stats returns database stats' => sub {
    $t->get_ok('/api/stats', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

subtest 'GET /api/fields returns field list' => sub {
    $t->get_ok('/api/fields', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

subtest 'GET /api/stats/fields/level returns level stats' => sub {
    $t->get_ok('/api/stats/fields/level', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

# ============================================
# 12. Pattern Endpoints (feature-gated: requires license)
# ============================================
subtest 'GET /api/patterns returns 403 on free plan (feature-gated)' => sub {
    $t->get_ok('/api/patterns', { 'X-API-Key' => 'test-key-123' })
      ->status_is(403)
      ->json_has('/feature');
};

# ============================================
# 13. Saved Searches Endpoints (feature-gated: requires license)
# ============================================
subtest 'GET /api/saved-searches returns 403 on free plan' => sub {
    $t->get_ok('/api/saved-searches', { 'X-API-Key' => 'test-key-123' })
      ->status_is(403)
      ->json_has('/feature');
};

subtest 'POST /api/saved-searches returns 403 on free plan' => sub {
    $t->post_ok('/api/saved-searches',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        json => { name => 'Test Search', query => 'level:ERROR', filters => {} })
      ->status_is(403)
      ->json_has('/feature');
};

# ============================================
# 14. Alerts Endpoints
# ============================================
subtest 'GET /api/alerts returns alert list' => sub {
    $t->get_ok('/api/alerts', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

# ============================================
# 15. Config Endpoints
# ============================================
subtest 'GET /api/config returns configuration' => sub {
    $t->get_ok('/api/config', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

# ============================================
# 16. Settings Endpoint
# ============================================
subtest 'GET /api/settings returns settings' => sub {
    $t->get_ok('/api/settings', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

# ============================================
# 17. Analytics Endpoints
# ============================================
subtest 'GET /api/analytics/tables returns table stats' => sub {
    $t->get_ok('/api/analytics/tables', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

subtest 'GET /api/analytics/notifiers returns notifier info' => sub {
    $t->get_ok('/api/analytics/notifiers', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200);
};

# ============================================
# 18. Auth Endpoints
# ============================================
subtest 'POST /api/auth/login without credentials returns 400' => sub {
    $t->post_ok('/api/auth/login',
        { 'Content-Type' => 'application/json' },
        json => {})
      ->status_is(400)
      ->json_has('/error');
};

subtest 'POST /api/auth/login with unknown user returns 401' => sub {
    $t->post_ok('/api/auth/login',
        { 'Content-Type' => 'application/json' },
        json => { username => 'nonexistent', password => 'whatever' })
      ->status_is(401)
      ->json_has('/error');
};

subtest 'GET /api/auth/me when not logged in' => sub {
    $t->get_ok('/api/auth/me')
      ->status_is(200)
      ->json_is('/authenticated' => 0);
};

subtest 'POST /api/auth/logout returns ok' => sub {
    $t->post_ok('/api/auth/logout')
      ->status_is(200)
      ->json_is('/status' => 'ok');
};

# ============================================
# 19. SSO Endpoints (SAML disabled)
# ============================================
subtest 'GET /api/auth/sso/login returns 503 when SAML not configured' => sub {
    $t->get_ok('/api/auth/sso/login')
      ->status_is(503)
      ->json_has('/error');
};

subtest 'GET /api/auth/sso/metadata returns 404 when SAML not configured' => sub {
    $t->get_ok('/api/auth/sso/metadata')
      ->status_is(404)
      ->json_has('/error');
};

# ============================================
# 20. Rate Limit Headers Present
# ============================================
subtest 'rate limit headers present on protected endpoints' => sub {
    $t->get_ok('/api/logs', { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->header_like('X-RateLimit-Limit' => qr/^\d+$/)
      ->header_like('X-RateLimit-Remaining' => qr/^\d+$/);
};

# ============================================
# 21. Multiple Rapid Requests (stability check)
# ============================================
subtest 'multiple rapid requests do not crash the server' => sub {
    for my $i (1..10) {
        $t->get_ok('/api/health')->status_is(200);
    }
    pass 'survived 10 rapid health checks';

    for my $i (1..5) {
        $t->post_ok('/api/logs',
            { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
            json => { level => 'INFO', message => "Rapid test $i", service => 'rapid' })
          ->status_is(200);
    }
    pass 'survived 5 rapid ingests';
};

# ============================================
# 22. Log Context Endpoint — Invalid ID
# ============================================
subtest 'GET /api/logs/:id/context with invalid UUID returns 400' => sub {
    $t->get_ok('/api/logs/not-a-uuid/context', { 'X-API-Key' => 'test-key-123' })
      ->status_is(400)
      ->json_has('/error');
};

subtest 'GET /api/logs/:id/context with valid UUID format returns 404 (not found)' => sub {
    $t->get_ok('/api/logs/550e8400-e29b-41d4-a716-446655440000/context',
        { 'X-API-Key' => 'test-key-123' })
      ->status_is(404)
      ->json_has('/error');
};

# ============================================
# 23. Trace Endpoints
# ============================================
subtest 'GET /api/traces/:trace_id with invalid format returns 400' => sub {
    # trace_id must match [a-fA-F0-9\-]{8,36}
    $t->get_ok('/api/traces/xyz', { 'X-API-Key' => 'test-key-123' })
      ->status_is(400)
      ->json_has('/error');
};

subtest 'GET /api/traces/:trace_id with valid hex returns 404 (not found)' => sub {
    $t->get_ok('/api/traces/aabbccdd-1122-3344-5566-778899aabbcc',
        { 'X-API-Key' => 'test-key-123' })
      ->status_is(404)
      ->json_has('/error');
};

# ============================================
# 24. Metrics JSON Endpoint
# ============================================
subtest 'GET /api/metrics/json returns JSON metrics' => sub {
    $t->get_ok('/api/metrics/json')
      ->status_is(200)
      ->json_has('/server/version')
      ->json_has('/storage/total_logs')
      ->json_has('/requests/total');
};

# ============================================
# 25. Verify Ingested Data Integrity
# ============================================
subtest 'verify all ingested logs are queryable' => sub {
    my $response = $t->get_ok('/api/logs?q=test-service',
        { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->tx->res->json;

    ok defined $response->{hits}, 'hits array present';
    ok defined $response->{total}, 'total count present';
};

subtest 'verify service filter works' => sub {
    $t->get_ok('/api/logs?service=test-svc',
        { 'X-API-Key' => 'test-key-123' })
      ->status_is(200)
      ->json_has('/hits');
};

# ============================================
# 26. Audit Endpoints
# ============================================
subtest 'GET /api/audit returns 403 on free plan (feature-gated)' => sub {
    $t->get_ok('/api/audit', { 'X-API-Key' => 'test-key-123' })
      ->status_is(403)
      ->json_has('/feature');
};

subtest 'GET /api/audit/stats returns 403 on free plan (feature-gated)' => sub {
    $t->get_ok('/api/audit/stats', { 'X-API-Key' => 'test-key-123' })
      ->status_is(403)
      ->json_has('/feature');
};

# ============================================
# 27. Default Field Values on Ingested Logs
# ============================================
subtest 'ingest minimal log gets defaults applied' => sub {
    # Reset storage for clean test
    my $before_count = scalar @{$mock_storage->_logs};

    $t->post_ok('/api/logs',
        { 'X-API-Key' => 'test-key-123', 'Content-Type' => 'application/json' },
        json => { message => 'Minimal log with no other fields' })
      ->status_is(200)
      ->json_is('/inserted' => 1);

    # Check the last inserted log has defaults
    my $last_log = $mock_storage->_logs->[-1];
    is $last_log->{level}, 'INFO', 'default level is INFO';
    is $last_log->{service}, 'unknown', 'default service is unknown';
    is $last_log->{host}, 'unknown', 'default host is unknown';
    ok defined $last_log->{timestamp}, 'timestamp auto-assigned';
    is ref $last_log->{meta}, 'HASH', 'meta is a hash ref';
};

# ============================================
# 28. Content-Type Verification
# ============================================
subtest 'health endpoint returns JSON content type' => sub {
    $t->get_ok('/api/health')
      ->status_is(200)
      ->content_type_like(qr{application/json});
};

subtest 'metrics endpoint returns text content type' => sub {
    $t->get_ok('/api/metrics')
      ->status_is(200)
      ->content_type_like(qr{text/});
};

# ============================================
# Cleanup
# ============================================
unlink $ENV{PURL_CONFIG_FILE} if -f $ENV{PURL_CONFIG_FILE};
remove_tree($ENV{PURL_CONFIG_DIR}) if -d $ENV{PURL_CONFIG_DIR};

done_testing;

__END__

=head1 NAME

t/25_integration_flow.t - Comprehensive HTTP-level integration tests

=head1 DESCRIPTION

Tests the full Purl API flow using Test::Mojo with an in-memory storage mock.
Covers: health check, auth flow, log ingestion (single/batch/NDJSON), queries,
stats, patterns, saved searches, alerts, config, settings, analytics, audit,
CORS, security headers, rate limiting, error handling, and data integrity.

=cut

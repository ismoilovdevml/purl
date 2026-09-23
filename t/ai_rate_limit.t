#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);

# ============================================
# #83: the LLM-backed endpoints (/api/ai/{query,analyze,explain}) spend a paid
# provider budget, and the only throttle was the global per-IP limit
# (1000 req/60s). They now have their own per-USERNAME limit
# (PURL_AI_RATE_LIMIT per 60s window) on the auth middleware's shared counter
# store. A caller without a session (API key, or an open instance) is keyed by
# client IP instead.
# ============================================

my $LIMIT = 3;
my $DIR;
BEGIN {
    $DIR = "/tmp/purl_ai_rate_limit_test_$$";
    delete $ENV{PURL_REDIS_URL};                         # in-memory counters
    delete $ENV{PURL_BROADCAST_MODE};
    $ENV{PURL_AI_RATE_LIMIT}   = '3';
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_API_KEYS}        = 'ai-rl-ingest-key';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'ai-rate-limit-test-secret-0123456789abcdef';
    $ENV{PURL_CONFIG_FILE}     = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}      = $DIR;
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
}
make_path($DIR);
END { remove_tree($DIR) if $DIR }

{
    package Purl::Storage::InMemory;
    use Moo;
    sub flush        { 1 }
    sub maybe_flush  { }
    sub get_metrics  { { queries_total => 0, inserts_total => 0, errors_total => 0, buffer_size => 0 } }
    sub log_audit_event    { 1 }
    sub _init_audit_schema { 1 }
}

my $storage = Purl::Storage::InMemory->new;

require Purl::API::Server;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $storage };
}

my $app = Purl::API::Server->create(config => { auth => { enabled => 1 } })->setup_routes;

use Test::Mojo;

sub login {
    my ($user, $pass) = @_;
    my $t = Test::Mojo->new($app);
    $t->post_ok('/api/auth/login', { 'Content-Type' => 'application/json' },
        json => { username => $user, password => $pass })
      ->status_is(200);
    return $t;
}

sub csrf {
    my ($t) = @_;
    $t->get_ok('/api/csrf-token');
    return $t->tx->res->json->{csrf_token};
}

# One AI call; returns the status. No provider is configured, so an allowed
# call answers 400 "AI not configured" — anything but 429 means "not limited".
sub ai_call {
    my ($t, $endpoint, %hdr) = @_;
    $t->post_ok("/api/ai/$endpoint", { 'Content-Type' => 'application/json', %hdr },
        json => { question => 'why are there errors', log => 'x' });
    return $t->tx->res->code;
}

my $admin = login('admin', 'StrongAdminPass123');
$admin->post_ok('/api/settings/users',
    { 'Content-Type' => 'application/json', 'X-CSRF-Token' => csrf($admin) },
    json => { username => 'vic', password => 'ViewerPass12345', role => 'viewer' })
  ->status_is(200);
my $viewer = login('vic', 'ViewerPass12345');

my %ADMIN_CSRF  = ('X-CSRF-Token' => csrf($admin));
my %VIEWER_CSRF = ('X-CSRF-Token' => csrf($viewer));

subtest "a user gets $LIMIT AI calls per window, across all AI endpoints" => sub {
    my @endpoints = qw(query analyze explain);
    for my $i (1 .. $LIMIT) {
        my $ep = $endpoints[($i - 1) % @endpoints];
        isnt ai_call($admin, $ep, %ADMIN_CSRF), 429, "call $i ($ep) allowed";
    }
    is ai_call($admin, 'explain', %ADMIN_CSRF), 429, 'call ' . ($LIMIT + 1) . ' is 429';
    $admin->json_like('/error' => qr/AI rate limit exceeded/, 'says why');
    my $retry = $admin->tx->res->json->{retry_after};
    ok $retry >= 1 && $retry <= 60, "retry_after is the time left in the window ($retry)";
    $admin->header_is('Retry-After' => $retry, 'Retry-After header matches');
    is ai_call($admin, 'query', %ADMIN_CSRF), 429, 'other AI endpoints share the budget';
};

subtest 'another user is unaffected' => sub {
    isnt ai_call($viewer, 'query', %VIEWER_CSRF), 429, 'viewer still allowed';
};

subtest 'non-LLM AI endpoints and the rest of the API are not limited' => sub {
    for (1 .. $LIMIT + 1) {
        $admin->get_ok('/api/ai/providers')->status_is(200, 'providers served');
        $admin->get_ok('/api/ai/suggest?q=err')->status_is(200, 'suggest served');
    }
    $admin->get_ok('/api/auth/me')->status_is(200);
};

subtest 'requests refused before the AI gate consume no AI budget' => sub {
    $admin->post_ok('/api/settings/users',
        { 'Content-Type' => 'application/json', %ADMIN_CSRF },
        json => { username => 'cara', password => 'CaraPass1234567', role => 'viewer' })
      ->status_is(200);
    my $cara = login('cara', 'CaraPass1234567');

    # CSRF-rejected (session, no token): 403 from the CSRF gate, never counted.
    for (1 .. $LIMIT + 1) {
        is ai_call($cara, 'query'), 403, 'no CSRF token: 403';
    }
    my %cara_csrf = ('X-CSRF-Token' => csrf($cara));
    isnt ai_call($cara, 'query', %cara_csrf), 429, "call $_ still allowed" for 1 .. $LIMIT;
    is ai_call($cara, 'query', %cara_csrf), 429, 'her budget starts only at the gate';

    # Unauthenticated (no session, no key): 401, never counted against the IP.
    my $anon = Test::Mojo->new($app);
    is ai_call($anon, 'query'), 401, 'unauthenticated: 401' for 1 .. $LIMIT + 1;
};

subtest 'no session: keyed by client IP' => sub {
    my $anon = Test::Mojo->new($app);
    my %key  = ('X-API-Key' => 'ai-rl-ingest-key');
    # The 401s above ran from this same IP: all $LIMIT calls must still pass.
    # API keys are refused by the AI controller (403), but each attempt still
    # counts against the caller's IP so a leaked key cannot hammer the gate.
    isnt ai_call($anon, 'query', %key), 429, "IP call $_ allowed" for 1 .. $LIMIT;
    is ai_call($anon, 'query', %key), 429, 'IP call ' . ($LIMIT + 1) . ' is 429';
    isnt ai_call($viewer, 'query', %VIEWER_CSRF), 429,
        'a signed-in user on the same IP keeps their own budget';
};

subtest 'PURL_AI_RATE_LIMIT=0 disables the limit' => sub {
    local $ENV{PURL_AI_RATE_LIMIT} = '0';
    isnt ai_call($admin, 'query', %ADMIN_CSRF), 429, 'limited user allowed again';
};

subtest 'invalid PURL_AI_RATE_LIMIT falls back to 20 and warns once per value' => sub {
    require Purl::API::Middleware::Auth;
    my $val;
    my $mw = Purl::API::Middleware::Auth->new(settings => MockAISettings->new(\$val));
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };

    for my $bad ('-1', '5.5', '20/min') {
        $val = $bad;
        is $mw->ai_rate_limit_max, 20, "'$bad' -> 20" for 1 .. 3;
    }
    is scalar(@warned), 3, 'one warning per distinct bad value, not per request';
    like $warned[$_], qr/Invalid ai\.rate_limit.*using 20/, "warning $_ says what happened"
        for 0 .. $#warned;

    @warned = ();
    $val = '7';  is $mw->ai_rate_limit_max, 7, 'valid value used';
    $val = '0';  is $mw->ai_rate_limit_max, 0, '0 (disabled) is valid';
    $val = undef; is $mw->ai_rate_limit_max, 20, 'unset -> default';
    is scalar(@warned), 0, 'valid and unset values do not warn';
};

{
    package MockAISettings;
    sub new { bless { v => $_[1] }, $_[0] }
    sub get { ${ $_[0]->{v} } }
}

done_testing;

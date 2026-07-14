#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Digest::SHA qw(hmac_sha256_hex);

use Purl::API::Middleware::Auth;

# ============================================================================
# BUG 1 regression: CSRF secret must be SHARED across prefork workers/replicas.
#
# Two Auth middleware instances model two independent workers (or replicas).
# generate_csrf_token() runs on worker A; verify_csrf_token() runs on worker B.
# Because session cookies are shared (app->secrets), a token minted anywhere
# must verify everywhere — otherwise ~75% of browser mutations 403 under 4
# workers, and ~always across replicas.
#
# We assert the token issued by instance A verifies on instance B (and vice
# versa) for EACH shared-secret source, and — documenting the single-process
# dev fallback — that WITHOUT any shared secret the two instances diverge.
# ============================================================================

# Fresh pair of "workers" each time so the lazy csrf_secret is built under the
# env/config currently in scope.
sub two_workers {
    my (%args) = @_;
    my $cfg = $args{config} // {};
    return (
        Purl::API::Middleware::Auth->new(config => $cfg),
        Purl::API::Middleware::Auth->new(config => $cfg),
    );
}

subtest 'PURL_CSRF_SECRET: token minted on A verifies on B (and vice versa)' => sub {
    local $ENV{PURL_CSRF_SECRET}   = 'shared-explicit-csrf-secret-xyz';
    local $ENV{PURL_SESSION_SECRET};
    delete $ENV{PURL_SESSION_SECRET};

    my ($a, $b) = two_workers();
    is $a->csrf_secret, $b->csrf_secret, 'both workers derived the SAME csrf_secret';

    my $tok_a = $a->generate_csrf_token('sess-123');
    my $tok_b = $b->generate_csrf_token('sess-456');

    ok $b->verify_csrf_token($tok_a), "A's token verifies on B (cross-worker)";
    ok $a->verify_csrf_token($tok_b), "B's token verifies on A (cross-worker)";
};

subtest 'shared session secret via ENV: cross-worker tokens verify' => sub {
    local $ENV{PURL_CSRF_SECRET};
    delete $ENV{PURL_CSRF_SECRET};
    local $ENV{PURL_SESSION_SECRET} = 'the-shared-session-secret-abcdef';

    my ($a, $b) = two_workers();
    is $a->csrf_secret, $b->csrf_secret, 'same session secret => same csrf_secret';
    isnt $a->csrf_secret, $ENV{PURL_SESSION_SECRET},
        'csrf_secret is HMAC-derived, NOT literally the cookie secret';

    my $tok = $a->generate_csrf_token('sid');
    ok $b->verify_csrf_token($tok), 'token from A verifies on B';
};

subtest 'shared session secret via CONFIG (server.session_secret): cross-worker' => sub {
    local $ENV{PURL_CSRF_SECRET};
    local $ENV{PURL_SESSION_SECRET};
    delete $ENV{PURL_CSRF_SECRET};
    delete $ENV{PURL_SESSION_SECRET};

    my $secret = 'persisted-config-session-secret-0011';
    my ($a, $b) = two_workers(config => { server => { session_secret => $secret } });

    is $a->csrf_secret, $b->csrf_secret,
        'workers reading the same persisted config secret agree';
    # Matches the documented derivation (fixed label keyed by the session secret).
    is $a->csrf_secret, hmac_sha256_hex('purl:csrf-token-secret:v1', $secret),
        'derivation is HMAC-SHA256(label, session_secret)';

    my $tok = $b->generate_csrf_token('sid2');
    ok $a->verify_csrf_token($tok), 'token from B verifies on A';
};

subtest 'PURL_CSRF_SECRET takes precedence over the session secret' => sub {
    local $ENV{PURL_CSRF_SECRET}    = 'explicit-wins';
    local $ENV{PURL_SESSION_SECRET} = 'ignored-when-explicit-set';

    my ($a) = two_workers();
    is $a->csrf_secret, 'explicit-wins', 'explicit env beats the derived value';
};

subtest 'NO shared secret => per-instance random (dev fallback) => tokens diverge' => sub {
    local $ENV{PURL_CSRF_SECRET};
    local $ENV{PURL_SESSION_SECRET};
    delete $ENV{PURL_CSRF_SECRET};
    delete $ENV{PURL_SESSION_SECRET};

    my ($a, $b) = two_workers();   # no shared source anywhere
    isnt $a->csrf_secret, $b->csrf_secret,
        'without a shared secret each worker gets its own random secret';

    my $tok_a = $a->generate_csrf_token('sid');
    ok $a->verify_csrf_token($tok_a), 'a token still verifies on its OWN worker';
    ok !$b->verify_csrf_token($tok_a),
        "cross-worker verify FAILS on the random fallback (this is the bug prefork must avoid)";
};

done_testing;

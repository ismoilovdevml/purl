#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Store::Counter;
use Purl::API::Middleware::Auth;

# ============================================================================
# FALLBACK PATH (no Redis) — MUST be behaviour-identical to the original
# per-worker hashref implementation. These run everywhere with no dependencies.
# ============================================================================

subtest 'Counter fallback: incr returns growing count, get reads it' => sub {
    my $s = Purl::Store::Counter->new;   # empty redis_url => pure local
    ok !$s->is_shared, 'no Redis configured => not shared (pure in-memory)';
    is $s->get('k'), 0, 'absent key reads 0';
    is $s->incr('k', 60), 1, 'first incr => 1';
    is $s->incr('k', 60), 2, 'second incr => 2';
    is $s->get('k'), 2, 'get reflects current count';
};

subtest 'Counter fallback: del resets' => sub {
    my $s = Purl::Store::Counter->new;
    $s->incr('x', 60) for 1 .. 3;
    is $s->get('x'), 3, 'count is 3';
    $s->del('x');
    is $s->get('x'), 0, 'after del count is 0';
};

subtest 'Counter fallback: TTL expiry starts a fresh window' => sub {
    my $s = Purl::Store::Counter->new;
    is $s->incr('t', 1), 1, 'first hit in 1s window';
    is $s->incr('t', 1), 2, 'second hit same window';
    sleep 2;
    is $s->get('t'), 0, 'expired window reads 0';
    is $s->incr('t', 1), 1, 'incr after expiry starts fresh at 1';
};

subtest 'Counter fallback: keys are isolated' => sub {
    my $s = Purl::Store::Counter->new;
    $s->incr('a', 60) for 1 .. 2;
    $s->incr('b', 60);
    is $s->get('a'), 2, 'key a independent';
    is $s->get('b'), 1, 'key b independent';
};

# ---- Auth wiring on the fallback path (same assertions as 06_middleware_auth) ----

subtest 'Auth rate limit: allows within limit, blocks excess' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 3, rate_limit_window => 60);
    ok $rl->check_rate_limit('10.0.0.1'), "req 1 allowed";
    ok $rl->check_rate_limit('10.0.0.1'), "req 2 allowed";
    ok $rl->check_rate_limit('10.0.0.1'), "req 3 allowed";
    ok !$rl->check_rate_limit('10.0.0.1'), 'req 4 blocked';
    ok $rl->check_rate_limit('10.0.0.2'), 'other IP unaffected';
};

subtest 'Auth get_rate_limit_remaining decrements' => sub {
    my $rl = Purl::API::Middleware::Auth->new(rate_limit_max => 10, rate_limit_window => 60);
    is $rl->get_rate_limit_remaining('3.3.3.3'), 10, 'full for new IP';
    $rl->check_rate_limit('3.3.3.3');
    is $rl->get_rate_limit_remaining('3.3.3.3'), 9, 'decremented';
};

subtest 'Auth username lockout: blocks after 5 failures, reset clears' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    ok $rl->check_username_rate_limit('admin'), 'new user allowed';
    $rl->record_failed_login('baduser') for 1 .. 5;
    ok !$rl->check_username_rate_limit('baduser'), 'blocked after 5 failures';
    ok $rl->check_username_rate_limit('otheruser'), 'other user unaffected';
    $rl->record_failed_login('resetme') for 1 .. 4;
    $rl->reset_failed_login('resetme');
    ok $rl->check_username_rate_limit('resetme'), 'allowed after reset';
};

subtest 'Auth username lockout: undef/empty are no-ops' => sub {
    my $rl = Purl::API::Middleware::Auth->new;
    ok $rl->check_username_rate_limit(undef), 'undef always passes';
    ok $rl->check_username_rate_limit(''), 'empty always passes';
    $rl->record_failed_login(undef);   # must not die
    $rl->reset_failed_login(undef);    # must not die
    pass 'edge cases do not die';
};

subtest 'Auth uses in-memory store when no Redis configured' => sub {
    # Simulate a clean deployment: no Redis env, no config URL. (Guard against
    # an ambient PURL_REDIS_URL from the shared-path proof leaking in.)
    local $ENV{PURL_REDIS_URL};
    local $ENV{PURL_BROADCAST_MODE};
    delete $ENV{PURL_REDIS_URL};
    delete $ENV{PURL_BROADCAST_MODE};
    my $rl = Purl::API::Middleware::Auth->new;
    ok !$rl->counter_store->is_shared, 'default deployment => in-memory, not shared';
};

subtest 'Auth respects redis.mode=local (opt-out of shared counters)' => sub {
    my $rl = Purl::API::Middleware::Auth->new(
        config => { redis => { url => 'redis://127.0.0.1:6379', mode => 'local' } },
    );
    ok !$rl->counter_store->is_shared, 'mode=local forces in-memory even with a URL';
};

# ============================================================================
# SHARED PATH (Redis) — proves the whole point: two independent instances that
# share one Redis see ONE counter. Skipped unless Mojo::Redis is installed AND
# a reachable Redis is provided via PURL_REDIS_URL (default redis://127.0.0.1:6379).
# ============================================================================

SKIP: {
    my $url = $ENV{PURL_REDIS_URL} || 'redis://127.0.0.1:6379';

    my $have_client = eval { require Mojo::Redis; 1 };
    skip 'Mojo::Redis not installed', 1 unless $have_client;

    # Probe reachability without blowing up the suite.
    my $reachable = eval { Mojo::Redis->new($url)->db->ping; 1 };
    skip "Redis not reachable at $url", 1 unless $reachable;

    # Unique prefix so repeated runs never collide.
    my $tag = "purltest:$$:" . int(rand(1_000_000));

    subtest 'shared counter is visible across two independent instances' => sub {
        my $a = Purl::Store::Counter->new(redis_url => $url);
        my $b = Purl::Store::Counter->new(redis_url => $url);
        ok $a->is_shared, 'instance A backed by Redis';
        ok $b->is_shared, 'instance B backed by Redis';

        my $key = "$tag:shared";
        is $a->incr($key, 120), 1, 'A increments to 1';
        is $b->incr($key, 120), 2, 'B sees A\'s increment and goes to 2';
        is $a->get($key), 2, 'A reads the shared value 2';
        is $b->get($key), 2, 'B reads the shared value 2';

        $a->del($key);
        is $b->get($key), 0, 'B sees the reset done by A';
    };

    subtest 'shared login lockout enforced across two workers' => sub {
        # Simulate two prefork workers each with their own Auth middleware,
        # both pointed at the same Redis. Five failures TOTAL must lock out.
        my $user = "$tag:victim";
        my $w1 = Purl::API::Middleware::Auth->new(
            config => { redis => { url => $url, mode => 'auto' } },
        );
        my $w2 = Purl::API::Middleware::Auth->new(
            config => { redis => { url => $url, mode => 'auto' } },
        );
        ok $w1->counter_store->is_shared, 'worker 1 shared';
        ok $w2->counter_store->is_shared, 'worker 2 shared';

        # 3 failures land on w1, 2 on w2 => 5 total across workers.
        $w1->record_failed_login($user) for 1 .. 3;
        $w2->record_failed_login($user) for 1 .. 2;

        ok !$w1->check_username_rate_limit($user), 'w1 sees lockout (5 total)';
        ok !$w2->check_username_rate_limit($user), 'w2 sees lockout (5 total)';

        $w1->reset_failed_login($user);
        ok $w2->check_username_rate_limit($user), 'reset on w1 visible on w2';
    };

    subtest 'Redis TTL expiry resets the window' => sub {
        my $s = Purl::Store::Counter->new(redis_url => $url);
        my $key = "$tag:ttl";
        is $s->incr($key, 1), 1, 'first hit, 1s TTL';
        is $s->incr($key, 1), 2, 'second hit same window';
        sleep 2;
        is $s->get($key), 0, 'after TTL, Redis key gone => 0';
        is $s->incr($key, 1), 1, 'fresh window after expiry';
        $s->del($key);
    };
}

done_testing;

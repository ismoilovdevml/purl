#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Store::Counter;

# ============================================================================
# Regression for issue #88: INCR succeeds, EXPIRE fails => the Redis key used
# to be left without a TTL forever (login lockout / AI rate limit stuck).
# Uses an in-process fake Redis so it runs everywhere, no server required.
# ============================================================================

{
    package FakeRedis;    ## no critic (Modules::ProhibitMultiplePackages)
    use strict;
    use warnings;

    sub new { return bless { data => {}, exp => {}, now => 1000, fail_expire => 0, expire_calls => 0 }, shift }
    sub db  { my ($s) = @_; return $s }

    sub advance { my ($s, $sec) = @_; $s->{now} += $sec; return }

    sub _purge {
        my ($s, $k) = @_;
        if (defined $s->{exp}{$k} && $s->{exp}{$k} <= $s->{now}) {
            delete $s->{data}{$k};
            delete $s->{exp}{$k};
        }
        return;
    }

    sub incrby {
        my ($s, $k, $n) = @_;
        $s->_purge($k);
        return $s->{data}{$k} = ($s->{data}{$k} // 0) + $n;
    }

    sub expire {
        my ($s, $k, $ttl) = @_;
        $s->{expire_calls}++;
        if ($s->{fail_expire} > 0) {
            $s->{fail_expire}--;
            die "simulated EXPIRE failure\n";
        }
        return 0 unless exists $s->{data}{$k};
        $s->{exp}{$k} = $s->{now} + $ttl;
        return 1;
    }

    sub ttl {
        my ($s, $k) = @_;
        $s->_purge($k);
        return -2 unless exists $s->{data}{$k};
        return -1 unless defined $s->{exp}{$k};
        return $s->{exp}{$k} - $s->{now};
    }

    sub get { my ($s, $k) = @_; $s->_purge($k); return $s->{data}{$k} }
    sub del { my ($s, $k) = @_; delete $s->{data}{$k}; delete $s->{exp}{$k}; return 1 }
}

sub shared_store {
    my ($fake) = @_;
    return Purl::Store::Counter->new(
        redis_url        => 'redis://fake:6379',
        _redis           => $fake,
        _redis_available => 1,
    );
}

subtest 'EXPIRE failure on first hit is repaired on the next hit' => sub {
    my $fake = FakeRedis->new;
    my $s    = shared_store($fake);
    $fake->{fail_expire} = 1;

    my $c1;
    {
        local $SIG{__WARN__} = sub { };
        $c1 = $s->incr('login:alice', 300);
    }
    is $c1, 1, 'INCR result returned even though EXPIRE failed';
    ok $s->is_shared, 'a failed EXPIRE does not demote the store to in-memory';
    is $fake->ttl('login:alice'), -1, 'key has no TTL right after the failure';

    is $s->incr('login:alice', 300), 2, 'second hit counts in Redis';
    my $ttl = $fake->ttl('login:alice');
    ok $ttl > 0 && $ttl <= 300, "second hit restored the TTL (got $ttl)";

    $fake->advance(301);
    is $s->get('login:alice'), 0, 'key expires: the lockout is not permanent';
    is $s->incr('login:alice', 300), 1, 'next hit starts a fresh window';
};

subtest 'a pre-existing key with no TTL gets one on the next hit' => sub {
    my $fake = FakeRedis->new;
    $fake->{data}{'ai:bob'} = 50;    # stuck key left by the old code
    my $s = shared_store($fake);

    is $s->incr('ai:bob', 60), 51, 'count continues';
    is $fake->ttl('ai:bob'), 60, 'stuck key now expires';
};

subtest 'healthy key: window stays fixed (EXPIRE not re-applied)' => sub {
    my $fake = FakeRedis->new;
    my $s    = shared_store($fake);

    $s->incr('rl:ip', 60);
    is $fake->{expire_calls}, 1, 'EXPIRE on first hit';
    $fake->advance(20);
    $s->incr('rl:ip', 60) for 1 .. 3;
    is $fake->{expire_calls}, 1, 'no EXPIRE on later hits of a healthy key';
    is $fake->ttl('rl:ip'), 40, 'TTL keeps counting down (fixed, not sliding)';
    is $s->ttl('rl:ip'), 40, 'Counter->ttl reports the same window';
};

subtest 'incr_by: repeated EXPIRE failures never lose counts or die' => sub {
    my $fake = FakeRedis->new;
    my $s    = shared_store($fake);
    $fake->{fail_expire} = 3;

    my @got;
    {
        local $SIG{__WARN__} = sub { };
        push @got, $s->incr_by('bytes', 10, 60) for 1 .. 3;
    }
    is_deeply \@got, [10, 20, 30], 'all increments land in Redis';
    is $fake->ttl('bytes'), -1, 'still no TTL while EXPIRE keeps failing';

    is $s->incr_by('bytes', 10, 60), 40, 'Redis recovers';
    is $fake->ttl('bytes'), 60, 'TTL applied as soon as EXPIRE works';
};

subtest 'in-memory fallback unchanged' => sub {
    my $s = Purl::Store::Counter->new;
    ok !$s->is_shared, 'no URL => local';
    is $s->incr('k', 60), 1, 'first';
    is $s->incr('k', 60), 2, 'second';
    ok $s->ttl('k') > 0, 'local window has a TTL';
};

done_testing;

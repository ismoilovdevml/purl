#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json decode_json);
use IO::Socket::INET;
use Time::HiRes qw(time);

# ============================================
# Check if Mojo::Redis is available
# ============================================
my $has_mojo_redis = eval { require Mojo::Redis; 1 };

# ============================================
# Module loads regardless of Mojo::Redis
# ============================================
use_ok('Purl::Broadcast::Redis');

# ============================================
# Construction without Mojo::Redis
# ============================================
subtest 'constructor with redis_url' => sub {
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://localhost:6379');
    ok $bc, 'created redis broadcaster';
    is $bc->redis_url, 'redis://localhost:6379', 'redis_url stored';
    is $bc->default_channel, 'purl:logs:broadcast', 'default channel';
};

# ============================================
# Fallback to local when Redis unavailable
# ============================================
subtest 'local fallback when redis unavailable' => sub {
    # Use a bogus URL that will fail to connect
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://invalid-host-xxx:9999');
    my @received;

    # Subscribe (should register locally even without Redis)
    my $id = $bc->subscribe('test:ch', sub { push @received, $_[0] });
    ok defined $id, 'subscribe returns ID even without Redis';
    is $bc->subscriber_count('test:ch'), 1, '1 local subscriber';

    # Publish (should fall back to local delivery)
    $bc->publish('test:ch', { msg => 'fallback' });

    is scalar @received, 1, 'received via local fallback';
    my $parsed = decode_json($received[0]);
    is $parsed->{msg}, 'fallback', 'message content correct';
};

# ============================================
# Unsubscribe works with local fallback
# ============================================
subtest 'unsubscribe with local fallback' => sub {
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://invalid-host-xxx:9999');
    my @received;

    my $id = $bc->subscribe('ch', sub { push @received, $_[0] });
    $bc->publish('ch', { n => 1 });
    is scalar @received, 1, 'received before unsubscribe';

    $bc->unsubscribe($id);
    is $bc->subscriber_count('ch'), 0, '0 after unsubscribe';

    $bc->publish('ch', { n => 2 });
    is scalar @received, 1, 'not received after unsubscribe';
};

# ============================================
# Multiple subscribers with local fallback
# ============================================
subtest 'multiple subscribers local fallback' => sub {
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://invalid-host-xxx:9999');
    my (@r1, @r2);

    $bc->subscribe('ch', sub { push @r1, $_[0] });
    $bc->subscribe('ch', sub { push @r2, $_[0] });

    is $bc->subscriber_count('ch'), 2, '2 subscribers';

    $bc->publish('ch', { data => 'multi' });

    is scalar @r1, 1, 'subscriber 1 received';
    is scalar @r2, 1, 'subscriber 2 received';
};

# ============================================
# is_connected is truthful and fails fast (issue #89)
# ============================================
SKIP: {
    skip 'Mojo::Redis not installed', 3 unless $has_mojo_redis;

    subtest 'is_connected false for a refused port, quickly' => sub {
        my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://127.0.0.1:1');
        my $t0 = time;
        my $connected;
        { local $SIG{__WARN__} = sub { }; $connected = $bc->is_connected; }
        my $took = time - $t0;
        ok !$connected, 'unreachable Redis => not connected';
        cmp_ok $took, '<', 2, sprintf('failed fast (%.3fs)', $took);
    };

    subtest 'is_connected false when the peer never answers PING' => sub {
        # A listening socket that is never accept()ed: TCP connects via the
        # backlog, but no Redis reply ever comes. Must hit connect_timeout.
        my $srv = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, Proto => 'tcp',
        ) or die "listen: $!";
        my $bc = Purl::Broadcast::Redis->new(
            redis_url       => 'redis://127.0.0.1:' . $srv->sockport,
            connect_timeout => 0.5,
        );
        my $t0 = time;
        my $connected;
        { local $SIG{__WARN__} = sub { }; $connected = $bc->is_connected; }
        my $took = time - $t0;
        ok !$connected, 'silent peer => not connected';
        cmp_ok $took, '<', 2, sprintf('bounded by connect_timeout (%.3fs)', $took);
    };

    subtest 'publish/subscribe fall back to local when unreachable' => sub {
        my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://127.0.0.1:1');
        my @got;
        local $SIG{__WARN__} = sub { };
        $bc->subscribe('ch', sub { push @got, $_[0] });
        $bc->publish('ch', { a => 1 });
        is scalar @got, 1, 'delivered locally';
        ok !$bc->is_connected, 'still reports not connected';
    };
}

# ============================================
# Publish array of logs (typical use case)
# ============================================
subtest 'publish array via local fallback' => sub {
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://invalid-host-xxx:9999');
    my @received;

    $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });

    my $logs = [
        { level => 'INFO', message => 'test1' },
        { level => 'ERROR', message => 'test2' },
    ];
    $bc->publish($bc->default_channel, $logs);

    is scalar @received, 1, 'received 1 message';
    my $parsed = decode_json($received[0]);
    is ref $parsed, 'ARRAY', 'decoded as array';
    is scalar @$parsed, 2, '2 logs in batch';
};

# ============================================
# Subscriber error does not break others
# ============================================
subtest 'subscriber error isolation' => sub {
    my $bc = Purl::Broadcast::Redis->new(redis_url => 'redis://invalid-host-xxx:9999');
    my @received;

    $bc->subscribe('ch', sub { die "boom" });
    $bc->subscribe('ch', sub { push @received, $_[0] });

    eval { $bc->publish('ch', { x => 1 }) };
    ok !$@, 'publish did not die';
    is scalar @received, 1, 'healthy subscriber received';
};

# ============================================
# Real Redis integration (skipped if unavailable)
# ============================================
SKIP: {
    my $redis_url = $ENV{PURL_REDIS_URL};
    skip 'Set PURL_REDIS_URL to run Redis integration tests', 3
        unless $redis_url && $has_mojo_redis;

    subtest 'real redis publish/subscribe' => sub {
        my $bc = Purl::Broadcast::Redis->new(redis_url => $redis_url);
        ok $bc->is_connected, 'connected to real Redis';

        my @received;
        $bc->subscribe('purl:test:integration', sub { push @received, $_[0] });

        # Give listener time to establish
        Mojo::IOLoop->timer(0.5 => sub {
            $bc->publish('purl:test:integration', { integration => 'test' });
        });

        # Wait for delivery
        Mojo::IOLoop->timer(1.5 => sub { Mojo::IOLoop->stop });
        Mojo::IOLoop->start;

        ok scalar @received >= 1, 'received via Redis';
    };

    subtest 'real redis subscriber count' => sub {
        my $bc = Purl::Broadcast::Redis->new(redis_url => $redis_url);
        $bc->subscribe('purl:test:count', sub { });
        $bc->subscribe('purl:test:count', sub { });
        is $bc->subscriber_count('purl:test:count'), 2, '2 subscribers on real Redis';
    };

    subtest 'real redis unsubscribe' => sub {
        my $bc = Purl::Broadcast::Redis->new(redis_url => $redis_url);
        my $id = $bc->subscribe('purl:test:unsub', sub { });
        is $bc->subscriber_count('purl:test:unsub'), 1, '1 subscriber';
        $bc->unsubscribe($id);
        is $bc->subscriber_count('purl:test:unsub'), 0, '0 after unsubscribe';
    };
}

done_testing;

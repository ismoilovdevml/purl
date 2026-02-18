#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json decode_json);

# ============================================
# Load module
# ============================================
use_ok('Purl::Broadcast::Local');

# ============================================
# Basic construction
# ============================================
subtest 'constructor' => sub {
    my $bc = Purl::Broadcast::Local->new();
    ok $bc, 'created local broadcaster';
    ok $bc->is_connected, 'always connected';
    is $bc->default_channel, 'purl:logs:broadcast', 'default channel';
};

# ============================================
# Subscribe and publish — single subscriber
# ============================================
subtest 'single subscriber receives message' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my @received;

    my $id = $bc->subscribe('test:channel', sub {
        push @received, $_[0];
    });

    ok defined $id, 'subscribe returns ID';
    is $bc->subscriber_count('test:channel'), 1, '1 subscriber';

    $bc->publish('test:channel', { level => 'ERROR', message => 'boom' });

    is scalar @received, 1, 'received 1 message';
    my $msg = decode_json($received[0]);
    is $msg->{level}, 'ERROR', 'message content correct';
    is $msg->{message}, 'boom', 'message body correct';
};

# ============================================
# Multiple subscribers
# ============================================
subtest 'multiple subscribers all receive message' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my (@r1, @r2, @r3);

    $bc->subscribe('ch', sub { push @r1, $_[0] });
    $bc->subscribe('ch', sub { push @r2, $_[0] });
    $bc->subscribe('ch', sub { push @r3, $_[0] });

    is $bc->subscriber_count('ch'), 3, '3 subscribers';

    $bc->publish('ch', { msg => 'hello' });

    is scalar @r1, 1, 'subscriber 1 received';
    is scalar @r2, 1, 'subscriber 2 received';
    is scalar @r3, 1, 'subscriber 3 received';
};

# ============================================
# Channel isolation
# ============================================
subtest 'channels are isolated' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my (@ch1, @ch2);

    $bc->subscribe('channel:one', sub { push @ch1, $_[0] });
    $bc->subscribe('channel:two', sub { push @ch2, $_[0] });

    $bc->publish('channel:one', { data => 'for-one' });

    is scalar @ch1, 1, 'channel:one received';
    is scalar @ch2, 0, 'channel:two did not receive';
};

# ============================================
# Unsubscribe
# ============================================
subtest 'unsubscribe stops delivery' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my @received;

    my $id = $bc->subscribe('ch', sub { push @received, $_[0] });
    $bc->publish('ch', { n => 1 });
    is scalar @received, 1, 'received before unsubscribe';

    $bc->unsubscribe($id);
    is $bc->subscriber_count('ch'), 0, '0 subscribers after unsubscribe';

    $bc->publish('ch', { n => 2 });
    is scalar @received, 1, 'did not receive after unsubscribe';
};

# ============================================
# Unsubscribe one of many
# ============================================
subtest 'unsubscribe one leaves others active' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my (@r1, @r2);

    my $id1 = $bc->subscribe('ch', sub { push @r1, $_[0] });
    my $id2 = $bc->subscribe('ch', sub { push @r2, $_[0] });

    $bc->unsubscribe($id1);
    $bc->publish('ch', { x => 1 });

    is scalar @r1, 0, 'unsubscribed does not receive';
    is scalar @r2, 1, 'remaining subscriber receives';
};

# ============================================
# Publish with no subscribers
# ============================================
subtest 'publish with no subscribers is safe' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my $count = $bc->publish('empty:channel', { data => 'test' });
    is $count, 0, 'returns 0 when no subscribers';
};

# ============================================
# Publish string (not hashref)
# ============================================
subtest 'publish raw JSON string' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my @received;

    $bc->subscribe('ch', sub { push @received, $_[0] });
    $bc->publish('ch', '{"raw":"json"}');

    is scalar @received, 1, 'received raw string';
    is $received[0], '{"raw":"json"}', 'string passed through unchanged';
};

# ============================================
# Publish array of logs (typical use case)
# ============================================
subtest 'publish array of logs' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my @received;

    $bc->subscribe($bc->default_channel, sub { push @received, $_[0] });

    my $logs = [
        { level => 'INFO',  message => 'startup complete' },
        { level => 'ERROR', message => 'connection refused' },
    ];
    $bc->publish($bc->default_channel, $logs);

    is scalar @received, 1, 'received 1 message (array)';
    my $parsed = decode_json($received[0]);
    is ref $parsed, 'ARRAY', 'decoded as array';
    is scalar @$parsed, 2, '2 logs in array';
    is $parsed->[0]{level}, 'INFO', 'first log level';
    is $parsed->[1]{message}, 'connection refused', 'second log message';
};

# ============================================
# Error in subscriber does not break others
# ============================================
subtest 'subscriber error does not break others' => sub {
    my $bc = Purl::Broadcast::Local->new();
    my @received;

    $bc->subscribe('ch', sub { die "intentional error" });
    $bc->subscribe('ch', sub { push @received, $_[0] });

    # Should not die, and second subscriber should still receive
    eval { $bc->publish('ch', { test => 1 }) };
    ok !$@, 'publish did not die';
    is scalar @received, 1, 'healthy subscriber still received message';
};

# ============================================
# subscriber_count for nonexistent channel
# ============================================
subtest 'subscriber_count for nonexistent channel' => sub {
    my $bc = Purl::Broadcast::Local->new();
    is $bc->subscriber_count('nonexistent'), 0, '0 for unknown channel';
    is $bc->subscriber_count(undef), 0, '0 for undef channel';
};

done_testing;

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use IO::Handle;
use IO::Select;
use Time::HiRes qw(time sleep);
use Mojo::JSON qw(decode_json);

# ============================================================================
# Issue #89: live tail across replicas. Two SEPARATE processes, each with its
# own Purl::Broadcast::Redis: a message published in one must reach a
# subscriber in the other through Redis. Skipped without PURL_REDIS_URL.
# ============================================================================

my $url = $ENV{PURL_REDIS_URL};
plan skip_all => 'Set PURL_REDIS_URL to run the cross-process Redis test' unless $url;
plan skip_all => 'Mojo::Redis not installed' unless eval { require Mojo::Redis; 1 };

require Purl::Broadcast::Redis;

my $channel = "purl:test:xproc:$$:" . int(rand(1e9));

pipe(my $from_child, my $to_parent) or die "pipe: $!";

my $pid = fork // die "fork: $!";
if ($pid == 0) {
    # ---- subscriber process (replica B) ----
    close $from_child;
    $to_parent->autoflush(1);
    my $bc = Purl::Broadcast::Redis->new(redis_url => $url);
    unless ($bc->is_connected) {
        print {$to_parent} "NOT_CONNECTED\n";
        exit 1;
    }
    $bc->subscribe($channel, sub {
        print {$to_parent} "GOT $_[0]\n";
        Mojo::IOLoop->stop;
    });
    Mojo::IOLoop->timer(10 => sub { Mojo::IOLoop->stop });
    Mojo::IOLoop->start;
    exit 0;
}

# ---- publisher process (replica A) ----
close $to_parent;
my $bc = Purl::Broadcast::Redis->new(redis_url => $url);
ok $bc->is_connected, 'publisher process connected to Redis';

# Wait until the child's SUBSCRIBE is registered on the server.
my $probe    = Mojo::Redis->new($url);
my $deadline = time + 5;
my $subs     = 0;
while (time < $deadline) {
    my ($r) = $probe->db->call(PUBSUB => NUMSUB => $channel);    # [channel, count]
    $subs = $r->[1] // 0;
    last if $subs;
    sleep 0.05;
}
is $subs, 1, 'subscriber process is listening on the channel';

ok $bc->publish($channel, { from => 'replica-a', pid => $$ }), 'published from the parent process';

my $line = '';
if (IO::Select->new($from_child)->can_read(5)) {
    $line = <$from_child> // '';
}
kill 'TERM', $pid unless $line;
waitpid $pid, 0;

like $line, qr/^GOT /, 'other process received the message via Redis';
my ($json) = $line =~ /^GOT (.*)$/;
my $msg = $json ? decode_json($json) : {};
is $msg->{from}, 'replica-a', 'payload intact';
is $msg->{pid}, $$, 'message came from the publisher process';

done_testing;

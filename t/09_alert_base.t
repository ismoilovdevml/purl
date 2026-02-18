#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Alert::Base is a role, create a concrete consumer
{
    package TestNotifier;
    use Moo;
    with 'Purl::Alert::Base';

    has 'deliver_result' => (is => 'rw', default => 1);
    has 'deliver_called' => (is => 'rw', default => 0);
    has 'last_message'   => (is => 'rw');

    sub deliver {
        my ($self, $message) = @_;
        $self->deliver_called($self->deliver_called + 1);
        $self->last_message($message);
        return $self->deliver_result;
    }
}

# ============================================
# Constructor and defaults
# ============================================
subtest 'default attributes' => sub {
    my $n = TestNotifier->new(name => 'test');
    is $n->name, 'test', 'name set';
    is $n->enabled, 1, 'enabled by default';
    is $n->throttle_seconds, 60, 'default throttle 60s';
    is $n->max_retries, 3, 'default 3 retries';
    is $n->_last_sent, 0, 'no last sent';
};

# ============================================
# can_send — throttle checking
# ============================================
subtest 'can_send when enabled and not throttled' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 0);
    ok $n->can_send, 'can send immediately with 0 throttle';
};

subtest 'can_send blocked when disabled' => sub {
    my $n = TestNotifier->new(name => 'test', enabled => 0);
    ok !$n->can_send, 'disabled notifier cannot send';
};

subtest 'can_send blocked during throttle window' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 3600);
    $n->_last_sent(time());
    ok !$n->can_send, 'blocked during throttle window';
};

# ============================================
# is_throttled — per-alert throttle
# ============================================
subtest 'is_throttled for new alert' => sub {
    my $n = TestNotifier->new(name => 'test');
    ok !$n->is_throttled('alert-1'), 'not throttled for new alert ID';
};

subtest 'is_throttled after mark_sent' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 3600);
    $n->_mark_sent('alert-2');
    ok $n->is_throttled('alert-2'), 'throttled after mark_sent';
    ok !$n->is_throttled('alert-3'), 'different alert not throttled';
};

subtest 'is_throttled with override period' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 1);
    $n->_mark_sent('alert-4');
    ok $n->is_throttled('alert-4', 3600), 'override to longer period still throttled';
};

subtest 'is_throttled returns 1 when disabled' => sub {
    my $n = TestNotifier->new(name => 'test', enabled => 0);
    is $n->is_throttled('any'), 1, 'disabled notifier always throttled';
};

# ============================================
# format_message
# ============================================
subtest 'format_message structure' => sub {
    my $n = TestNotifier->new(name => 'test');
    my $alert = {
        name           => 'High Error Rate',
        query          => 'level:ERROR',
        threshold      => 10,
        window_minutes => 5,
    };
    my $context = { count => 15 };

    my $msg = $n->format_message($alert, $context);
    is $msg->{title}, 'Alert: High Error Rate', 'title formatted';
    is $msg->{alert}, 'High Error Rate', 'alert name';
    is $msg->{query}, 'level:ERROR', 'query preserved';
    is $msg->{count}, 15, 'count from context';
    is $msg->{threshold}, 10, 'threshold from alert';
    is $msg->{window}, 5, 'window from alert';
    ok defined $msg->{time}, 'time present';
};

subtest 'format_message severity critical' => sub {
    my $n = TestNotifier->new(name => 'test');
    my $msg = $n->format_message(
        { name => 'Test', threshold => 5 },
        { count => 15 },  # 15 >= 5*2 = critical
    );
    is $msg->{severity}, 'critical', 'count >= 2x threshold is critical';
};

subtest 'format_message severity warning' => sub {
    my $n = TestNotifier->new(name => 'test');
    my $msg = $n->format_message(
        { name => 'Test', threshold => 10 },
        { count => 12 },  # 12 < 10*2 = warning
    );
    is $msg->{severity}, 'warning', 'count < 2x threshold is warning';
};

subtest 'format_message with missing fields' => sub {
    my $n = TestNotifier->new(name => 'test');
    my $msg = $n->format_message({}, {});
    is $msg->{count}, 0, 'missing count defaults to 0';
    is $msg->{threshold}, 0, 'missing threshold defaults to 0';
    is $msg->{window}, 5, 'missing window defaults to 5';
    is $msg->{query}, '', 'missing query defaults to empty';
};

# ============================================
# notify — full flow
# ============================================
subtest 'notify sends when can_send' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 0);
    my $result = $n->notify(
        { name => 'Alert', threshold => 5, window_minutes => 5, query => 'test' },
        { count => 10 },
    );
    ok $result, 'notify succeeded';
    is $n->deliver_called, 1, 'deliver called once';
    ok defined $n->last_message, 'message passed to deliver';
    is $n->last_message->{alert}, 'Alert', 'alert name in message';
};

subtest 'notify blocked by throttle' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 3600);
    $n->_last_sent(time());
    my $result = $n->notify({ name => 'Alert' }, {});
    ok !$result, 'notify blocked by throttle';
    is $n->deliver_called, 0, 'deliver not called';
};

subtest 'notify blocked when disabled' => sub {
    my $n = TestNotifier->new(name => 'test', enabled => 0);
    my $result = $n->notify({ name => 'Alert' }, {});
    ok !$result, 'notify blocked when disabled';
};

subtest 'notify updates _last_sent on success' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 0);
    my $before = $n->_last_sent;
    $n->notify({ name => 'Alert', threshold => 1 }, { count => 1 });
    ok $n->_last_sent > $before, '_last_sent updated after successful send';
};

subtest 'notify does not update _last_sent on failure' => sub {
    my $n = TestNotifier->new(name => 'test', throttle_seconds => 0, deliver_result => 0);
    my $before = time();
    $n->_last_sent(0);
    $n->notify({ name => 'Alert', threshold => 1 }, { count => 1 });
    is $n->_last_sent, 0, '_last_sent unchanged on delivery failure';
};

# ============================================
# _send_with_retry
# ============================================
subtest 'retry succeeds on first attempt' => sub {
    my $n = TestNotifier->new(name => 'test');
    my $attempts = 0;
    my $result = $n->_send_with_retry(sub {
        $attempts++;
        return 1;
    });
    ok $result, 'success returned';
    is $attempts, 1, 'only one attempt needed';
};

subtest 'retry on failure then success' => sub {
    my $n = TestNotifier->new(name => 'test', max_retries => 3);
    my $attempts = 0;
    my $result = $n->_send_with_retry(sub {
        $attempts++;
        return 1 if $attempts >= 2;
        die "transient error";
    });
    ok $result, 'eventually succeeds';
    is $attempts, 2, 'retried once';
};

subtest 'retry gives up after max_retries' => sub {
    my $n = TestNotifier->new(name => 'test', max_retries => 2);
    my $attempts = 0;
    my $result = $n->_send_with_retry(sub {
        $attempts++;
        die "persistent error";
    });
    ok !$result, 'fails after retries exhausted';
    is $attempts, 2, 'tried max_retries times';
};

subtest 'retry no retry on 4xx client error' => sub {
    my $n = TestNotifier->new(name => 'test', max_retries => 3);
    my $attempts = 0;
    my $result = $n->_send_with_retry(sub {
        $attempts++;
        return { success => 0, status => 403 };
    });
    ok !$result, 'fails on 4xx';
    is $attempts, 1, 'no retry for client error';
};

done_testing;

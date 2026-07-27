#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Purl::Storage::ClickHouse::Alerts;

# check_alerts() counts rows inside a rolling window, so one incident stays
# above threshold for the whole window. With the server-side scheduler ticking
# every 60s that turns a single incident into one notification per tick.
# alert_in_cooldown() is what stops that.

my $NOW = 1_800_000_000;

sub alert {
    my (%o) = @_;
    return {
        window_minutes    => $o{window} // 5,
        last_triggered_ts => $o{last},
        now_ts            => $o{now} // $NOW,
    };
}

subtest 'never fired always notifies' => sub {
    # ClickHouse DateTime defaults to epoch 0 for a row that never triggered.
    ok !Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(alert(last => 0)),
        'last_triggered = 0 is not in cooldown';
    ok !Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(alert(last => undef)),
        'missing last_triggered is not in cooldown';
};

subtest 'one notification per window, not per tick' => sub {
    my $w = 5;    # 300s window

    # This is the regression: the scheduler fires at 60s intervals and each
    # tick still sees the same rows. Only the first tick may notify.
    for my $elapsed (0, 60, 120, 180, 240, 299) {
        ok Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(
            alert(window => $w, last => $NOW - $elapsed)
            ),
            "${elapsed}s after firing: suppressed";
    }

    ok !Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(
        alert(window => $w, last => $NOW - 300)
        ),
        '300s (a full window) after firing: notifies again';

    ok !Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(
        alert(window => $w, last => $NOW - 900)
        ),
        'long past the window: notifies again';
};

subtest 'cooldown tracks the alert window' => sub {
    # A 60-minute window must not re-notify after 5 minutes.
    ok Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(
        alert(window => 60, last => $NOW - 300)
        ),
        '60m window still suppressed 5m after firing';

    # A 1-minute window should be free to notify again after 1 minute.
    ok !Purl::Storage::ClickHouse::Alerts::alert_in_cooldown(
        alert(window => 1, last => $NOW - 60)
        ),
        '1m window notifies again after 60s';
};

subtest 'bad window values fall back to 5 minutes' => sub {
    for my $bad (undef, '', 0, -1, 'abc') {
        my $a = alert(last => $NOW - 60);
        $a->{window_minutes} = $bad;
        ok Purl::Storage::ClickHouse::Alerts::alert_in_cooldown($a),
            'window=' . (defined $bad ? "'$bad'" : 'undef') . ' still suppresses at 60s';
    }
};

done_testing();

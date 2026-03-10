#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Alerts;

# ============================================
# Mock objects (same pattern as t/15_controller_alerts.t)
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless {}, $_[0] }
    sub header { }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReqHeaders;
    sub new { bless {}, $_[0] }

    package MockReq;
    sub new { bless { body => $_[1] // '', headers => MockReqHeaders->new }, $_[0] }
    sub body { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockAlertCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1]),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[3] // {},
            params   => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{$_[1]} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        my $s = { role => 'admin' };
        return defined $key ? $s->{$key} : $s;
    }

    package MockAlertStorage;
    sub new { bless { alerts => $_[1] // [] }, $_[0] }
    sub get_alerts { return $_[0]->{alerts} }
    sub create_alert {
        my ($self, %params) = @_;
        $self->{created} = \%params;
        return 1;
    }
    sub update_alert { $_[0]->{updated_id} = $_[1]; return 1 }
    sub delete_alert { $_[0]->{deleted_id} = $_[1]; return 1 }
    sub check_alerts { return $_[0]->{triggered} // [] }

    package MockNotifier;
    sub new { bless { sent => 0 }, $_[0] }
    sub send_test { $_[0]->{sent} = 1; return 1 }
    sub notify { $_[0]->{sent} = 1; return 1 }
    sub name { 'mock' }
}

# ============================================
# Alert with empty name
# ============================================
subtest 'create alert with empty name returns 400' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => '', query => 'level:ERROR', threshold => 10 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'empty name returns 400';
};

subtest 'create alert with no name field returns 400' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ query => 'level:ERROR', threshold => 10 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing name returns 400';
};

subtest 'create alert with whitespace-only name' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => '   ', query => 'test', threshold => 1 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    # Whitespace name is truthy in Perl, so it should be accepted
    is $c->rendered->{json}{status}, 'ok', 'whitespace name accepted (truthy in Perl)';
};

# ============================================
# Alert with very long query
# ============================================
subtest 'create alert with very long query' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $long_query = 'error' x 2000;  # 10KB query
    my $body = encode_json({ name => 'Long Query Alert', query => $long_query, threshold => 5 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', 'long query alert created';
    is $storage->{created}{query}, $long_query, 'long query preserved in storage';
};

# ============================================
# Alert with threshold of 0
# ============================================
subtest 'create alert with threshold 0' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'Zero Threshold', query => 'level:ERROR', threshold => 0 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', 'threshold 0 alert created';
    is $storage->{created}{threshold}, 0, 'threshold 0 stored';
};

# ============================================
# Alert with negative window_minutes
# ============================================
subtest 'create alert with negative window_minutes' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({
        name           => 'Negative Window',
        query          => 'level:ERROR',
        threshold      => 10,
        window_minutes => -5,
    });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    # The controller passes through to storage without validating window_minutes
    is $c->rendered->{json}{status}, 'ok', 'negative window_minutes accepted (no validation in controller)';
    is $storage->{created}{window_minutes}, -5, 'negative window stored as-is';
};

# ============================================
# Alert channels with missing config
# ============================================
subtest 'test notification with unconfigured telegram' => sub {
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => MockAlertStorage->new,
        notifiers => {},  # No notifiers configured
    );
    my $c = MockAlertCtrl->new(undef, { type => 'telegram' });

    $ctrl->test_notification($c);
    is $c->rendered->{status}, 400, 'unconfigured telegram returns 400';
    like $c->rendered->{json}{error}, qr/not configured/, 'error mentions not configured';
};

subtest 'test notification with unconfigured slack' => sub {
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => MockAlertStorage->new,
        notifiers => {},
    );
    my $c = MockAlertCtrl->new(undef, { type => 'slack' });

    $ctrl->test_notification($c);
    is $c->rendered->{status}, 400, 'unconfigured slack returns 400';
};

subtest 'test notification with unconfigured webhook' => sub {
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => MockAlertStorage->new,
        notifiers => {},
    );
    my $c = MockAlertCtrl->new(undef, { type => 'webhook' });

    $ctrl->test_notification($c);
    is $c->rendered->{status}, 400, 'unconfigured webhook returns 400';
};

# ============================================
# Duplicate alert names
# ============================================
subtest 'create alert with duplicate name succeeds (no uniqueness check)' => sub {
    my $existing = [
        { id => '1', name => 'High Errors', enabled => 1 },
    ];
    my $storage = MockAlertStorage->new($existing);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'High Errors', query => 'level:ERROR', threshold => 5 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    # Controller does not enforce name uniqueness
    is $c->rendered->{json}{status}, 'ok', 'duplicate name accepted (no uniqueness enforcement)';
};

# ============================================
# Alert with invalid JSON body
# ============================================
subtest 'create alert with invalid JSON' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new('not json at all');

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'invalid JSON returns 400';
};

subtest 'create alert with empty body' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new('');

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'empty body returns 400';
};

# ============================================
# Update alert edge cases
# ============================================
subtest 'update alert with empty body' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new('', { id => 'some-uuid' });

    $ctrl->update($c);
    # decode_json on empty string fails, body becomes undef
    # But the controller tries to dereference $body as hash in storage call
    # This tests the error handling path
    my $r = $c->rendered;
    ok defined $r, 'update with empty body handled';
};

subtest 'update alert with invalid JSON body' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new('invalid json', { id => 'some-uuid' });

    $ctrl->update($c);
    my $r = $c->rendered;
    ok defined $r, 'update with invalid JSON handled';
};

# ============================================
# Remove alert edge cases
# ============================================
subtest 'remove alert with empty id' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new(undef, { id => '' });

    $ctrl->remove($c);
    is $c->rendered->{status}, 400, 'empty id returns 400';
};

# ============================================
# Check alerts with triggered results
# ============================================
subtest 'check with triggered alerts but no notifiers' => sub {
    my $storage = MockAlertStorage->new;
    $storage->{triggered} = [
        { name => 'Test Alert', count => 10, notify_type => 'telegram' },
    ];
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => $storage,
        notifiers => {},  # No notifiers
    );
    my $c = MockAlertCtrl->new;

    $ctrl->check($c);
    my $r = $c->rendered;
    is scalar @{$r->{json}{triggered}}, 1, '1 alert triggered';
    is scalar @{$r->{json}{notifications}}, 0, 'no notifications sent (no notifiers)';
};

subtest 'check with webhook alert and notify_target' => sub {
    my $storage = MockAlertStorage->new;
    $storage->{triggered} = [
        {
            name          => 'Webhook Alert',
            count         => 5,
            notify_type   => 'webhook',
            notify_target => 'https://example.com/hook',
        },
    ];
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => $storage,
        notifiers => {},
    );
    my $c = MockAlertCtrl->new;

    # This will try to create a Purl::Alert::Webhook and call notify
    # which needs HTTP - it may fail but should not crash
    $ctrl->check($c);
    my $r = $c->rendered;
    ok defined $r, 'webhook check with notify_target handled';
    is scalar @{$r->{json}{triggered}}, 1, 'alert still in triggered list';
};

# ============================================
# Alert list edge cases
# ============================================
subtest 'list with empty alerts array' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new;

    $ctrl->list($c);
    is scalar @{$c->rendered->{json}{alerts}}, 0, 'empty alerts list returned';
};

subtest 'list with many alerts' => sub {
    my @alerts = map { { id => $_, name => "Alert $_", enabled => 1 } } 1..100;
    my $storage = MockAlertStorage->new(\@alerts);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new;

    $ctrl->list($c);
    is scalar @{$c->rendered->{json}{alerts}}, 100, '100 alerts returned';
};

# ============================================
# Alert limit enforcement with mixed enabled/disabled
# ============================================
subtest 'alert limit counts only enabled alerts' => sub {
    my $existing = [
        { id => '1', name => 'A1', enabled => 1 },
        { id => '2', name => 'A2', enabled => 0 },  # disabled
        { id => '3', name => 'A3', enabled => 1 },
        { id => '4', name => 'A4', enabled => 0 },  # disabled
    ];
    my $storage = MockAlertStorage->new($existing);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'New', query => 'test', threshold => 1 });
    my $c = MockAlertCtrl->new($body, {}, {
        license_info => {
            plan   => 'free',
            limits => { alerts => 3 },
        },
    });

    $ctrl->create($c);
    # Only 2 enabled alerts exist, limit is 3, so should succeed
    is $c->rendered->{json}{status}, 'ok', 'alert created when only 2 of 4 are enabled (limit 3)';
};

subtest 'alert limit blocks when enabled count equals limit' => sub {
    my $existing = [
        { id => '1', name => 'A1', enabled => 1 },
        { id => '2', name => 'A2', enabled => 1 },
        { id => '3', name => 'A3', enabled => 1 },
    ];
    my $storage = MockAlertStorage->new($existing);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'New', query => 'test', threshold => 1 });
    my $c = MockAlertCtrl->new($body, {}, {
        license_info => {
            plan   => 'free',
            limits => { alerts => 3 },
        },
    });

    $ctrl->create($c);
    is $c->rendered->{status}, 403, 'blocked when enabled count equals limit';
};

done_testing;

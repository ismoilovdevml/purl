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
# Mock objects
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
    sub session { return {} }

    package MockAlertStorage;
    sub new { bless { alerts => $_[1] // [] }, $_[0] }
    sub get_alerts { return $_[0]->{alerts} }
    sub create_alert { $_[0]->{created} = { @_[1..$#_] }; return 1 }
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
# list
# ============================================
subtest 'list returns alerts' => sub {
    my $alerts = [
        { id => '1', name => 'High Errors', enabled => 1 },
        { id => '2', name => 'Slow Queries', enabled => 0 },
    ];
    my $storage = MockAlertStorage->new($alerts);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new;

    $ctrl->list($c);
    my $r = $c->rendered;
    is scalar @{$r->{json}{alerts}}, 2, '2 alerts returned';
};

# ============================================
# create
# ============================================
subtest 'create alert with valid body' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'New Alert', query => 'level:ERROR', threshold => 10 });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{json}{status}, 'ok', 'alert created';
};

subtest 'create alert without name returns 400' => sub {
    my $storage = MockAlertStorage->new([]);
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ query => 'level:ERROR' });
    my $c = MockAlertCtrl->new($body);

    $ctrl->create($c);
    is $c->rendered->{status}, 400, 'missing name returns 400';
};

subtest 'create alert enforces limit' => sub {
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
    is $c->rendered->{status}, 403, 'limit exceeded returns 403';
};

# ============================================
# update
# ============================================
subtest 'update alert' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $body = encode_json({ name => 'Updated Name' });
    my $c = MockAlertCtrl->new($body, { id => 'alert-uuid' });

    $ctrl->update($c);
    is $c->rendered->{json}{status}, 'ok', 'alert updated';
};

subtest 'update alert without ID returns 400' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new('{}', {});

    $ctrl->update($c);
    is $c->rendered->{status}, 400, 'missing ID returns 400';
};

# ============================================
# remove
# ============================================
subtest 'remove alert' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new(undef, { id => 'del-uuid' });

    $ctrl->remove($c);
    is $c->rendered->{json}{status}, 'ok', 'alert deleted';
};

subtest 'remove alert without ID returns 400' => sub {
    my $storage = MockAlertStorage->new;
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new(undef, {});

    $ctrl->remove($c);
    is $c->rendered->{status}, 400, 'missing ID returns 400';
};

# ============================================
# check
# ============================================
subtest 'check with no triggered alerts' => sub {
    my $storage = MockAlertStorage->new;
    $storage->{triggered} = [];
    my $ctrl = Purl::API::Controller::Alerts->new(storage => $storage);
    my $c = MockAlertCtrl->new;

    $ctrl->check($c);
    is scalar @{$c->rendered->{json}{triggered}}, 0, 'no alerts triggered';
};

# ============================================
# test_notification
# ============================================
subtest 'test_notification success' => sub {
    my $notifier = MockNotifier->new;
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => MockAlertStorage->new,
        notifiers => { telegram => $notifier },
    );
    my $c = MockAlertCtrl->new(undef, { type => 'telegram' });

    $ctrl->test_notification($c);
    ok $c->rendered->{json}{success}, 'notification sent';
    is $c->rendered->{json}{type}, 'telegram', 'correct type';
};

subtest 'test_notification unknown type' => sub {
    my $ctrl = Purl::API::Controller::Alerts->new(
        storage   => MockAlertStorage->new,
        notifiers => {},
    );
    my $c = MockAlertCtrl->new(undef, { type => 'sms' });

    $ctrl->test_notification($c);
    is $c->rendered->{status}, 400, 'unknown notifier returns 400';
};

done_testing;

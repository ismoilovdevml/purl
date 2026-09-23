#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use JSON::XS ();

my $json = JSON::XS->new->utf8;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }
    sub info  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReqBody;
    sub new  { bless { body => $_[1] // '' }, $_[0] }
    sub body { $_[0]->{body} }

    package MockReqHeaders;
    sub new    { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} }

    package MockReq;
    sub new {
        bless {
            body    => $_[1] // '',
            headers => MockReqHeaders->new($_[2] // {}),
        }, $_[0];
    }
    sub body    { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        my ($class, %args) = @_;
        bless {
            params   => $args{params}  // {},
            rendered => undef,
            stash    => $args{stash}   // {},
            session  => $args{session} // {},
            app      => MockApp->new,
            req      => MockReq->new($args{body} // '', $args{headers} // {}),
        }, $class;
    }
    sub param {
        my ($self, $key) = @_;
        return $self->{params}{$key};
    }
    sub app { $_[0]->{app} }
    sub req { $_[0]->{req} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        # The principal check_auth records for a signed-in user
        # (Purl::Util::Principal); require_role reads it, not the cookie.
        $self->{stash}{'purl.principal'} //= { via => 'session', username => $self->{session}{username}, role => $self->{session}{role} // 'viewer' };
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }

    package MockStorage;
    sub new {
        bless {
            agents       => $_[1] // [],
            registered   => [],
            heartbeats   => [],
            deleted      => [],
        }, $_[0];
    }
    sub get_agents {
        my ($self) = @_;
        return $self->{agents};
    }
    sub register_agent {
        my ($self, $params) = @_;
        push @{$self->{registered}}, $params;
    }
    sub heartbeat_agent {
        my ($self, $params) = @_;
        push @{$self->{heartbeats}}, $params;
    }
    sub delete_agent {
        my ($self, $id) = @_;
        push @{$self->{deleted}}, $id;
    }
}

# ============================================
# 1. Module loads correctly
# ============================================
use_ok('Purl::API::Controller::Agents');

# ============================================
# 2. List endpoint
# ============================================
subtest 'list - returns empty agents array' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {},
    );
    $ctrl->list($c);

    my $r = $c->rendered;
    ok $r, 'response rendered';
    is ref $r->{json}{agents}, 'ARRAY', 'agents is an array';
    is scalar @{$r->{json}{agents}}, 0, 'empty agents list';
    is $r->{json}{total}, 0, 'total is 0';
    ok !exists $r->{json}{limit}, 'no plan-driven limit object in response';
};

subtest 'list - returns agents with data' => sub {
    my $agents = [
        {
            id            => 'uuid-1',
            hostname      => 'web-01',
            os            => 'Ubuntu 22.04',
            ip_address    => '192.168.1.10',
            agent_version => '0.1.0',
            api_key_label => 'prod-key',
            status        => 'online',
            last_heartbeat_at => '2026-02-24T14:30:00Z',
            registered_at     => '2026-02-24T10:00:00Z',
        },
        {
            id            => 'uuid-2',
            hostname      => 'db-01',
            os            => 'Rocky Linux 9',
            ip_address    => '192.168.1.20',
            agent_version => '0.1.0',
            status        => 'offline',
            last_heartbeat_at => '2026-02-24T12:00:00Z',
            registered_at     => '2026-02-24T09:00:00Z',
        },
    ];
    my $storage = MockStorage->new($agents, 2);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {},
    );
    $ctrl->list($c);

    my $r = $c->rendered;
    is $r->{json}{total}, 2, 'total is 2';
    is $r->{json}{agents}[0]{hostname}, 'web-01', 'first agent hostname';
    is $r->{json}{agents}[1]{hostname}, 'db-01', 'second agent hostname';
};

# ============================================
# 3. Register endpoint
# ============================================
subtest 'register - succeeds with valid body' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({
        hostname      => 'web-01',
        os            => 'Ubuntu 22.04',
        ip_address    => '192.168.1.10',
        agent_version => '0.1.0',
        api_key_label => 'prod-key',
        labels        => { env => 'production' },
    });

    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'register succeeds';
    like $r->{json}{message}, qr/registered/i, 'success message';

    # Verify storage was called correctly
    is scalar @{$storage->{registered}}, 1, 'one agent registered';
    is $storage->{registered}[0]{hostname}, 'web-01', 'hostname passed to storage';
    is $storage->{registered}[0]{os}, 'Ubuntu 22.04', 'os passed to storage';
    is $storage->{registered}[0]{ip_address}, '192.168.1.10', 'ip passed to storage';
    is $storage->{registered}[0]{agent_version}, '0.1.0', 'version passed to storage';
    like $storage->{registered}[0]{labels}, qr/production/, 'labels JSON includes env';
};

subtest 'register - fails without hostname' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({ os => 'Ubuntu' });

    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{status}, 400, 'missing hostname returns 400';
    like $r->{json}{error}, qr/hostname/i, 'error mentions hostname';
    is scalar @{$storage->{registered}}, 0, 'nothing registered';
};

subtest 'register - fails with empty body' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        body  => '',
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{status}, 400, 'empty body returns 400';
    is scalar @{$storage->{registered}}, 0, 'nothing registered';
};

subtest 'register - not capped by an agent count' => sub {
    my $storage = MockStorage->new([ map { { id => $_ } } 1 .. 100 ]);  # 100 agents already
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({ hostname => 'server-101' });

    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'registration allowed with 100 existing agents';
    is scalar @{$storage->{registered}}, 1, 'agent registered despite 100 existing';
};

subtest 'register - handles optional fields gracefully' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({ hostname => 'minimal-server' });

    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'register with only hostname succeeds';
    my $reg = $storage->{registered}[0];
    is $reg->{hostname}, 'minimal-server', 'hostname set';
    is $reg->{os}, '', 'os defaults to empty';
    is $reg->{ip_address}, '', 'ip defaults to empty';
    is $reg->{agent_version}, '', 'version defaults to empty';
};

subtest 'register - labels without hash ignored' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({
        hostname => 'test-server',
        labels   => 'not-a-hash',
    });

    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'non-hash labels do not crash';
    is $storage->{registered}[0]{labels}, '', 'non-hash labels become empty';
};

# ============================================
# 4. Heartbeat endpoint
# ============================================
subtest 'heartbeat - succeeds with valid body' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({
        hostname      => 'web-01',
        ip_address    => '192.168.1.10',
        agent_version => '0.1.1',
    });

    my $c = MockCtrl->new(body => $body);
    $ctrl->heartbeat($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'heartbeat succeeds';
    like $r->{json}{message}, qr/[Hh]eartbeat/i, 'heartbeat message';

    is scalar @{$storage->{heartbeats}}, 1, 'one heartbeat recorded';
    is $storage->{heartbeats}[0]{hostname}, 'web-01', 'hostname in heartbeat';
    is $storage->{heartbeats}[0]{ip_address}, '192.168.1.10', 'ip in heartbeat';
    is $storage->{heartbeats}[0]{agent_version}, '0.1.1', 'version in heartbeat';
};

subtest 'heartbeat - fails without hostname' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({ ip_address => '192.168.1.10' });

    my $c = MockCtrl->new(body => $body);
    $ctrl->heartbeat($c);

    my $r = $c->rendered;
    is $r->{status}, 400, 'missing hostname returns 400';
    like $r->{json}{error}, qr/hostname/i, 'error mentions hostname';
    is scalar @{$storage->{heartbeats}}, 0, 'no heartbeat recorded';
};

subtest 'heartbeat - empty body returns 400' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(body => '');
    $ctrl->heartbeat($c);

    my $r = $c->rendered;
    is $r->{status}, 400, 'empty body returns 400';
};

# ============================================
# 5. Remove endpoint
# ============================================
subtest 'remove - admin can delete agent' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        params  => { id => 'agent-uuid-123' },
        session => { role => 'admin' },
    );
    $ctrl->remove($c);

    my $r = $c->rendered;
    is $r->{json}{status}, 'ok', 'admin remove succeeds';
    like $r->{json}{message}, qr/removed/i, 'remove message';
    is scalar @{$storage->{deleted}}, 1, 'one agent deleted';
    is $storage->{deleted}[0], 'agent-uuid-123', 'correct ID deleted';
};

subtest 'remove - non-admin gets 403' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        params  => { id => 'agent-uuid-123' },
        session => { role => 'viewer' },
    );
    $ctrl->remove($c);

    my $r = $c->rendered;
    is $r->{status}, 403, 'viewer cannot delete agents';
    is scalar @{$storage->{deleted}}, 0, 'nothing deleted';
};

subtest 'remove - operator gets 403' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        params  => { id => 'agent-uuid-123' },
        session => { role => 'operator' },
    );
    $ctrl->remove($c);

    my $r = $c->rendered;
    is $r->{status}, 403, 'operator cannot delete agents';
    is scalar @{$storage->{deleted}}, 0, 'nothing deleted';
};

# ============================================
# 6. Response structure validation
# ============================================
subtest 'list response has expected keys' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $c = MockCtrl->new(
        stash => {},
    );
    $ctrl->list($c);

    my $r = $c->rendered->{json};
    ok exists $r->{agents}, 'agents key exists';
    ok exists $r->{total}, 'total key exists';
    ok !exists $r->{limit}, 'no plan-driven limit key';
};

subtest 'register response has expected keys' => sub {
    my $storage = MockStorage->new([], 0);
    my $ctrl = Purl::API::Controller::Agents->new(storage => $storage);

    my $body = $json->encode({ hostname => 'test' });
    my $c = MockCtrl->new(
        body  => $body,
        stash => {},
    );
    $ctrl->register($c);

    my $r = $c->rendered->{json};
    ok exists $r->{status}, 'status key exists';
    ok exists $r->{message}, 'message key exists';
};

done_testing;

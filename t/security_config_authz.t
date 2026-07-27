#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Config;
use Purl::API::Controller::Audit;

# ============================================================
# REGRESSION: missing authorization on Config and Audit endpoints.
#
# Config.pm had NO require_role at all:
#   * POST /api/config/test-clickhouse took host+port from the request body,
#     performed an outbound HTTP GET and returned the result — so ANY viewer
#     could port-scan the internal network and read cloud metadata endpoints
#     (169.254.169.254). Classic SSRF.
#   * PUT /api/config/retention could be changed by any viewer.
#   * test_clickhouse also did `eval { decode_json(...) }` without checking the
#     result, then read $body->{host} — autovivifying on undef.
#
# Audit.pm had NO require_role either, so any viewer could read every login,
# source IP and admin action.
#
# Pinned here: viewer => 403, admin => allowed, private/metadata host =>
# refused, malformed JSON => 400.
# ============================================================

# --------------------------------------------
# Mocks
# --------------------------------------------
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockReqHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub header { $_[0]->{h}{ $_[1] } }

    package MockReq;
    sub new { bless { body => $_[1] // '', headers => MockReqHeaders->new($_[2]) }, $_[0] }
    sub body    { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    # new(role => 'viewer', body => '...', params => {}, headers => {})
    sub new {
        my ($class, %args) = @_;
        return bless {
            role     => $args{role},
            req      => MockReq->new($args{body}, $args{headers}),
            params   => $args{params} // {},
            stash    => $args{stash}  // {},
            rendered => undef,
            app      => MockApp->new,
        }, $class;
    }
    sub req { $_[0]->{req} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{ $_[1] } }
    sub render { my ($s, %a) = @_; $s->{rendered} = \%a }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        return $self->{role}     if ($key // '') eq 'role';
        return 'someuser'        if ($key // '') eq 'username';
        return undef;
    }

    package MockStorage;
    sub new { bless { retention_calls => 0, cleared => 0 }, $_[0] }
    sub stats { { total_logs => 0, db_size_mb => 0 } }
    sub update_retention { $_[0]{retention_calls}++; return { ok => 1 } }
    sub get_audit_logs   { [ { actor => 'admin', action => 'login', ip => '1.2.3.4' } ] }
    sub count_audit_logs { 1 }
    sub get_audit_stats  { { total => 1 } }
}

sub config_ctrl {
    return Purl::API::Controller::Config->new(
        storage     => MockStorage->new,
        config      => {},
        main_config => {},
        cache       => {},
    );
}

# ============================================================
# update_retention — admin only
# ============================================================
subtest 'PUT /api/config/retention: viewer 403, admin allowed' => sub {
    my $ctrl = config_ctrl();

    my $viewer = MockCtrl->new(role => 'viewer', body => encode_json({ days => 7 }));
    $ctrl->update_retention($viewer);
    is $viewer->rendered->{status}, 403, 'viewer is refused';
    like $viewer->rendered->{json}{error}, qr/permission/i, 'error mentions permissions';

    my $operator = MockCtrl->new(role => 'operator', body => encode_json({ days => 7 }));
    $ctrl->update_retention($operator);
    is $operator->rendered->{status}, 403, 'operator is refused too (admin-only)';

    my $admin = MockCtrl->new(role => 'admin', body => encode_json({ days => 7 }));
    $ctrl->update_retention($admin);
    is $admin->rendered->{status}, undef, 'admin is not blocked';
    is $admin->rendered->{json}{retention_days}, 7, 'admin retention update applied';
};

# ============================================================
# clear_cache — admin only
# ============================================================
subtest 'DELETE /api/cache: viewer 403, admin allowed' => sub {
    my $ctrl = config_ctrl();

    my $viewer = MockCtrl->new(role => 'viewer');
    $ctrl->clear_cache($viewer);
    is $viewer->rendered->{status}, 403, 'viewer cannot flush the cache';

    my $admin = MockCtrl->new(role => 'admin');
    $ctrl->clear_cache($admin);
    is $admin->rendered->{json}{status}, 'ok', 'admin can flush the cache';
};

# ============================================================
# test_clickhouse — admin only + SSRF filter + JSON validation
# ============================================================
subtest 'POST /api/config/test-clickhouse: viewer is refused' => sub {
    my $ctrl = config_ctrl();
    my $viewer = MockCtrl->new(
        role => 'viewer',
        body => encode_json({ host => '169.254.169.254', port => 80 }),
    );
    $ctrl->test_clickhouse($viewer);
    is $viewer->rendered->{status}, 403, 'viewer cannot reach the outbound-probe endpoint';
    like $viewer->rendered->{json}{error}, qr/permission/i, 'error mentions permissions';
};

subtest 'test-clickhouse refuses private / metadata targets even for admin' => sub {
    local %ENV = %ENV;
    delete $ENV{PURL_ALLOW_PRIVATE_DB_TEST};
    $ENV{PURL_CLICKHOUSE_HOST} = 'clickhouse.internal.example';   # != any probe below

    my $ctrl = config_ctrl();

    my %blocked = (
        'cloud metadata endpoint' => '169.254.169.254',
        'RFC1918 10/8'            => '10.0.0.7',
        'RFC1918 192.168/16'      => '192.168.1.1',
        'RFC1918 172.16/12'       => '172.16.5.4',
        'loopback'                => '127.0.0.1',
        'IPv6 loopback'           => '::1',
    );

    for my $label (sort keys %blocked) {
        my $admin = MockCtrl->new(
            role => 'admin',
            body => encode_json({ host => $blocked{$label}, port => 8123 }),
        );
        $ctrl->test_clickhouse($admin);
        is $admin->rendered->{status}, 400, "$label ($blocked{$label}) is refused";
        like $admin->rendered->{json}{error}, qr/Refusing to connect/i,
            "$label refusal is explicit";
    }
};

subtest 'test-clickhouse rejects hosts carrying a scheme, path or credentials' => sub {
    local %ENV = %ENV;
    delete $ENV{PURL_ALLOW_PRIVATE_DB_TEST};
    $ENV{PURL_CLICKHOUSE_HOST} = 'clickhouse.internal.example';

    my $ctrl = config_ctrl();
    for my $host ('http://evil.example/x', 'evil.example/../admin', 'user@evil.example') {
        my $admin = MockCtrl->new(role => 'admin', body => encode_json({ host => $host }));
        $ctrl->test_clickhouse($admin);
        is $admin->rendered->{status}, 400, "'$host' is refused";
    }
};

subtest 'test-clickhouse rejects a non-numeric port' => sub {
    local %ENV = %ENV;
    $ENV{PURL_CLICKHOUSE_HOST} = 'clickhouse.internal.example';
    my $ctrl = config_ctrl();
    my $admin = MockCtrl->new(
        role => 'admin',
        body => encode_json({ host => 'db.example.com', port => '80; rm -rf' }),
    );
    $ctrl->test_clickhouse($admin);
    is $admin->rendered->{status}, 400, 'non-numeric port is refused';
    like $admin->rendered->{json}{error}, qr/port/i, 'error mentions the port';
};

subtest 'test-clickhouse returns 400 on malformed JSON instead of autovivifying' => sub {
    my $ctrl = config_ctrl();
    my $admin = MockCtrl->new(role => 'admin', body => 'this is not json{{{');
    $ctrl->test_clickhouse($admin);
    is $admin->rendered->{status}, 400, 'malformed body returns 400';
    like $admin->rendered->{json}{error}, qr/Invalid JSON/i, 'error names the cause';
};

subtest 'test-clickhouse still allows the server own configured ClickHouse host' => sub {
    local %ENV = %ENV;
    delete $ENV{PURL_ALLOW_PRIVATE_DB_TEST};
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';       # nothing listening => fast refusal

    my $ctrl = config_ctrl();

    # Empty body == "test my CURRENT connection" — must not be SSRF-blocked.
    my $admin = MockCtrl->new(role => 'admin', body => '');
    $ctrl->test_clickhouse($admin);
    unlike $admin->rendered->{json}{error} // '', qr/Refusing to connect/i,
        'empty body probes the configured host, not blocked';

    # Explicitly naming the configured host is equally allowed.
    my $admin2 = MockCtrl->new(role => 'admin', body => encode_json({ host => '127.0.0.1' }));
    $ctrl->test_clickhouse($admin2);
    unlike $admin2->rendered->{json}{error} // '', qr/Refusing to connect/i,
        'the configured host is trusted even though it is loopback';
};

subtest 'PURL_ALLOW_PRIVATE_DB_TEST opts a LAN operator back in' => sub {
    local %ENV = %ENV;
    $ENV{PURL_ALLOW_PRIVATE_DB_TEST} = '1';
    $ENV{PURL_CLICKHOUSE_HOST} = 'clickhouse.internal.example';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';

    my $ctrl = config_ctrl();
    my $admin = MockCtrl->new(
        role => 'admin',
        body => encode_json({ host => '127.0.0.1', port => 19999 }),
    );
    $ctrl->test_clickhouse($admin);
    unlike $admin->rendered->{json}{error} // '', qr/Refusing to connect/i,
        'explicit opt-in allows a private target';
};

# ============================================================
# Audit — admin only
# ============================================================
subtest 'GET /api/audit: viewer 403, admin allowed' => sub {
    my $ctrl = Purl::API::Controller::Audit->new(
        storage => MockStorage->new, config => {}, cache => {});

    my $viewer = MockCtrl->new(role => 'viewer');
    $ctrl->list($viewer);
    is $viewer->rendered->{status}, 403, 'viewer cannot read the audit trail';
    ok !exists $viewer->rendered->{json}{logs}, 'and gets no log data';

    my $operator = MockCtrl->new(role => 'operator');
    $ctrl->list($operator);
    is $operator->rendered->{status}, 403, 'operator cannot read it either';

    my $admin = MockCtrl->new(role => 'admin');
    $ctrl->list($admin);
    is $admin->rendered->{status}, undef, 'admin is not blocked';
    is scalar @{ $admin->rendered->{json}{logs} }, 1, 'admin receives the audit entries';
};

subtest 'GET /api/audit/stats: viewer 403, admin allowed' => sub {
    my $ctrl = Purl::API::Controller::Audit->new(
        storage => MockStorage->new, config => {}, cache => {});

    my $viewer = MockCtrl->new(role => 'viewer');
    $ctrl->stats($viewer);
    is $viewer->rendered->{status}, 403, 'viewer cannot read audit stats';

    my $admin = MockCtrl->new(role => 'admin');
    $ctrl->stats($admin);
    is_deeply $admin->rendered->{json}{stats}, { total => 1 }, 'admin receives audit stats';
};

done_testing;

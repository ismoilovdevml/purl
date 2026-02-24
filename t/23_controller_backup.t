#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Backup;

# ============================================
# Mock objects
# ============================================
{
    package MockLog;
    sub new   { bless {}, $_[0] }
    sub error { }
    sub warn  { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new    { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if @_ > 2; $_[0]->{h}{$_[1]} }

    package MockRes;
    sub new     { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReqHeaders;
    sub new              { bless { h => $_[1] // {} }, $_[0] }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockReq;
    sub new {
        bless {
            body    => $_[1] // '',
            params  => $_[2] // {},
            headers => MockReqHeaders->new($_[3] // {}),
        }, $_[0];
    }
    sub body    { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1], $_[2]),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[3] // {},
            params   => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req    { $_[0]->{req} }
    sub res    { $_[0]->{res} }
    sub app    { $_[0]->{app} }
    sub param  { $_[0]->{params}{$_[1]} }
    sub render { my ($self, %args) = @_; $self->{rendered} = \%args }
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

    package MockBackupStorage;
    sub new {
        bless {
            backups        => $_[1] // [],
            created        => undef,
            restored       => undef,
            deleted        => undef,
            fail_create    => 0,
            fail_restore   => 0,
            fail_delete    => 0,
        }, $_[0];
    }
    sub list_backups {
        return $_[0]->{backups};
    }
    sub create_backup {
        my ($self, %params) = @_;
        die "Create failed" if $self->{fail_create};
        $self->{created} = \%params;
        return {
            id         => 'test_backup_001',
            name       => $params{name} // 'test_backup',
            target_path => '/app/backups/test_backup_001',
            tables     => ['logs', 'alerts'],
            size_bytes => 1024,
            rows_total => 100,
            status     => 'completed',
        };
    }
    sub restore_backup {
        my ($self, $id) = @_;
        die "Restore failed" if $self->{fail_restore};
        die "Backup not found" unless $id;
        $self->{restored} = $id;
        return {
            backup_id => $id,
            tables    => ['logs', 'alerts'],
            rows      => 100,
            status    => 'completed',
        };
    }
    sub delete_backup {
        my ($self, $id) = @_;
        die "Delete failed" if $self->{fail_delete};
        die "Backup not found" unless $id;
        $self->{deleted} = $id;
        return { status => 'deleted', id => $id };
    }
    sub create_backup_archive {
        my ($self, $id) = @_;
        die "Backup not found" unless $id;
        die "Archive creation failed" if $self->{fail_archive};
        $self->{archived} = $id;
        return "/app/backups/${id}.tar.gz";
    }
    sub cleanup_old_backups {
        my ($self, $retention_days) = @_;
        $self->{cleaned_retention} = $retention_days;
        return 2;
    }
    sub upload_backup_to_s3 {
        my ($self, $id, $s3_config) = @_;
        die "S3 upload failed" if $self->{fail_s3};
        $self->{s3_uploaded} = $id;
        return { id => $id, target_type => 's3', target_path => "s3://bucket/$id.tar.gz" };
    }
}

# ============================================
# list
# ============================================
subtest 'list returns backups' => sub {
    my $backups = [
        { id => 'b1', name => 'daily_backup', status => 'completed', size_bytes => 2048 },
        { id => 'b2', name => 'manual_backup', status => 'running', size_bytes => 0 },
    ];
    my $storage = MockBackupStorage->new($backups);
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->list($c);

    ok $c->rendered, 'rendered response';
    is scalar @{$c->rendered->{json}{backups}}, 2, '2 backups returned';
    is $c->rendered->{json}{backups}[0]{name}, 'daily_backup', 'first backup name';
};

subtest 'list returns empty when no backups' => sub {
    my $storage = MockBackupStorage->new([]);
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->list($c);

    is scalar @{$c->rendered->{json}{backups}}, 0, 'empty list';
};

# ============================================
# create
# ============================================
subtest 'create backup with name' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $body    = encode_json({ name => 'my_backup' });
    my $c       = MockCtrl->new($body);

    $ctrl->create($c);

    is $c->rendered->{json}{status}, 'ok', 'status ok';
    is $c->rendered->{json}{backup}{name}, 'my_backup', 'backup name';
    is $c->rendered->{json}{backup}{status}, 'completed', 'backup completed';
    ok $storage->{created}, 'storage create_backup called';
    is $storage->{created}{name}, 'my_backup', 'name passed to storage';
};

subtest 'create backup without name uses default' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new('{}');

    $ctrl->create($c);

    is $c->rendered->{json}{status}, 'ok', 'status ok';
    ok !defined $storage->{created}{name}, 'no name passed, storage uses default';
};

subtest 'create backup with empty body' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new('');

    $ctrl->create($c);

    is $c->rendered->{json}{status}, 'ok', 'handles empty body gracefully';
};

subtest 'create backup failure returns 500' => sub {
    my $storage = MockBackupStorage->new;
    $storage->{fail_create} = 1;
    my $ctrl = Purl::API::Controller::Backup->new(storage => $storage);
    my $c    = MockCtrl->new('{}');

    $ctrl->create($c);

    is $c->rendered->{status}, 500, 'returns 500 on failure';
    like $c->rendered->{json}{error}, qr/Create failed/, 'error message';
};

# ============================================
# restore
# ============================================
subtest 'restore backup with valid id' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $body    = encode_json({ id => 'test_backup_001' });
    my $c       = MockCtrl->new($body);

    $ctrl->restore($c);

    is $c->rendered->{json}{status}, 'ok', 'status ok';
    is $c->rendered->{json}{restore}{backup_id}, 'test_backup_001', 'correct backup id';
    is $storage->{restored}, 'test_backup_001', 'restore called with correct id';
};

subtest 'restore without id returns 400' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new('{}');

    $ctrl->restore($c);

    is $c->rendered->{status}, 400, 'returns 400';
    like $c->rendered->{json}{error}, qr/required/i, 'error about required id';
};

subtest 'restore failure returns 500' => sub {
    my $storage = MockBackupStorage->new;
    $storage->{fail_restore} = 1;
    my $ctrl = Purl::API::Controller::Backup->new(storage => $storage);
    my $body = encode_json({ id => 'bad_backup' });
    my $c    = MockCtrl->new($body);

    $ctrl->restore($c);

    is $c->rendered->{status}, 500, 'returns 500 on failure';
};

# ============================================
# remove
# ============================================
subtest 'delete backup with valid id' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new(undef, { id => 'test_backup_001' });

    $ctrl->remove($c);

    is $c->rendered->{json}{status}, 'ok', 'status ok';
    is $storage->{deleted}, 'test_backup_001', 'delete called with correct id';
};

subtest 'delete without id returns 400' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->remove($c);

    is $c->rendered->{status}, 400, 'returns 400';
    like $c->rendered->{json}{error}, qr/required/i, 'error about required id';
};

subtest 'delete failure returns 500' => sub {
    my $storage = MockBackupStorage->new;
    $storage->{fail_delete} = 1;
    my $ctrl = Purl::API::Controller::Backup->new(storage => $storage);
    my $c    = MockCtrl->new(undef, { id => 'test_backup_001' });

    $ctrl->remove($c);

    is $c->rendered->{status}, 500, 'returns 500 on failure';
};

# ============================================
# download
# ============================================
subtest 'download without id returns 400' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->download($c);

    is $c->rendered->{status}, 400, 'returns 400';
    like $c->rendered->{json}{error}, qr/required/i, 'error about required id';
};

subtest 'download calls create_backup_archive' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new(undef, { id => 'test_backup_001' });

    # download calls reply->asset which MockCtrl doesn't support,
    # so it will fail in safe_execute — but we verify archive was requested
    $ctrl->download($c);

    is $storage->{archived}, 'test_backup_001', 'archive requested for correct id';
};

# ============================================
# schedule
# ============================================
subtest 'get_schedule returns defaults' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->get_schedule($c);

    ok $c->rendered, 'rendered response';
    is $c->rendered->{json}{schedule}{enabled}, 0, 'schedule disabled by default';
    is $c->rendered->{json}{schedule}{interval_hours}, 24, 'default interval 24h';
    is $c->rendered->{json}{schedule}{retention_days}, 30, 'default retention 30d';
};

# ============================================
# S3 config
# ============================================
subtest 'get_s3_config returns defaults' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new;

    $ctrl->get_s3_config($c);

    ok $c->rendered, 'rendered response';
    is $c->rendered->{json}{s3}{enabled}, 0, 'S3 disabled by default';
    is $c->rendered->{json}{s3}{region}, 'us-east-1', 'default region';
};

subtest 'upload_to_s3 without id returns 400' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $c       = MockCtrl->new('{}');

    $ctrl->upload_to_s3($c);

    is $c->rendered->{status}, 400, 'returns 400';
    like $c->rendered->{json}{error}, qr/required/i, 'error about required id';
};

subtest 'upload_to_s3 without s3 config returns 400' => sub {
    my $storage = MockBackupStorage->new;
    my $ctrl    = Purl::API::Controller::Backup->new(storage => $storage);
    my $body    = Mojo::JSON::encode_json({ id => 'test_backup_001' });
    my $c       = MockCtrl->new($body);

    $ctrl->upload_to_s3($c);

    is $c->rendered->{status}, 400, 'returns 400';
    like $c->rendered->{json}{error}, qr/S3 not configured/i, 'error about S3 config';
};

done_testing;

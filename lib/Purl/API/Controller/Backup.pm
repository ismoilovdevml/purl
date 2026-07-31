package Purl::API::Controller::Backup;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);
use Purl::Storage::S3;

extends 'Purl::API::Controller::Base';

has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

# Single resolution point for S3 credentials in this controller — restore,
# delete and upload all need them, and each having its own copy is how the
# three drifted apart in the first place.
sub _s3_config {
    my ($self) = @_;
    return Purl::Storage::S3->config_from(settings => $self->settings);
}

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        my $backups = $self->storage->list_backups();
        $c->render(json => { backups => $backups });
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) } // {};
        my $name = $body->{name};
        my $backup_dir = $ENV{PURL_BACKUP_DIR} // '/app/backups';

        my $result = $self->storage->create_backup(
            name       => $name,
            backup_dir => $backup_dir,
        );

        $c->render(json => {
            status => 'ok',
            backup => $result,
        });
    });
}

sub restore {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) } // {};
        my $id = $body->{id};

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        # 'append' (default) keeps the historical behaviour; 'replace'
        # TRUNCATEs each table first, which is what makes a repeated restore
        # idempotent instead of doubling every row.
        my $mode = $body->{mode} // 'append';
        unless ($mode eq 'append' || $mode eq 'replace') {
            $self->render_error($c, "Invalid mode '$mode' (expected 'append' or 'replace')", 400);
            return;
        }

        # s3_config is passed unconditionally: a backup whose target_path is an
        # s3:// URI has to be downloaded before it can be restored at all.
        my $result = $self->storage->restore_backup(
            $id,
            mode      => $mode,
            s3_config => $self->_s3_config,
        );

        $c->render(json => {
            status  => 'ok',
            restore => $result,
        });
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $id = $c->param('id');

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        # s3_config so the remote object is deleted too — otherwise removing a
        # backup only drops the metadata row and the bucket grows forever.
        my $result = $self->storage->delete_backup($id, s3_config => $self->_s3_config);

        $c->render(json => { status => 'ok' });
    });
}

sub download {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        my $id = $c->param('id');
        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $archive_path = $self->storage->create_backup_archive($id);

        $c->res->headers->content_type('application/gzip');
        $c->res->headers->content_disposition(
            qq{attachment; filename="${id}.tar.gz"}
        );

        require Mojo::Asset::File;
        my $asset = Mojo::Asset::File->new(path => $archive_path);
        $c->reply->asset($asset);
    });
}

sub get_schedule {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        my $s = $self->settings;
        my $schedule = {
            enabled        => $s ? $s->get('backup', 'schedule_enabled') // 0 : 0,
            interval_hours => $s ? $s->get('backup', 'schedule_interval_hours') // 24 : 24,
            retention_days => $s ? $s->get('backup', 'retention_days') // 30 : 30,
            from_env       => $ENV{PURL_BACKUP_SCHEDULE_ENABLED} ? 1 : 0,
            # Per-key truth. The scalar `from_env` above is a single flag for
            # the whole panel and stays for the current UI, but it only tracks
            # PURL_BACKUP_SCHEDULE_ENABLED — so a field pinned by
            # PURL_BACKUP_RETENTION_DAYS still renders editable and now 409s on
            # save. This map says exactly which inputs to disable.
            from_env_keys  => $self->env_flags('backup'),
        };

        $c->render(json => { schedule => $schedule });
    });
}

sub update_schedule {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) } // {};

        # The wire names differ from the config keys, so the mapping is spelled
        # out — but WHICH of them the environment owns is not: that comes from
        # is_from_env via %ENV_MAP. The old single check on
        # PURL_BACKUP_SCHEDULE_ENABLED let an interval or retention edit through
        # while PURL_BACKUP_SCHEDULE_INTERVAL_HOURS / PURL_BACKUP_RETENTION_DAYS
        # kept winning on read — a saved value that never applied.
        my %changes;
        my %wire_to_key = (
            enabled        => 'schedule_enabled',
            interval_hours => 'schedule_interval_hours',
            retention_days => 'retention_days',
        );
        for my $wire (keys %wire_to_key) {
            $changes{ $wire_to_key{$wire} } = $body->{$wire} if defined $body->{$wire};
        }
        return if $self->reject_env_managed($c, 'backup', \%changes);

        if (defined $body->{enabled}) {
            $self->settings->set('backup', 'schedule_enabled', $body->{enabled} ? 1 : 0);
        }
        if (defined $body->{interval_hours}) {
            my $hours = int($body->{interval_hours});
            $hours = 1  if $hours < 1;
            $hours = 168 if $hours > 168;
            $self->settings->set('backup', 'schedule_interval_hours', $hours);
        }
        if (defined $body->{retention_days}) {
            my $days = int($body->{retention_days});
            $days = 1   if $days < 1;
            $days = 365 if $days > 365;
            $self->settings->set('backup', 'retention_days', $days);
        }

        $c->render(json => {
            status  => 'ok',
            message => 'Backup schedule updated. Restart required to apply schedule changes.',
        });
    });
}

sub upload_to_s3 {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) } // {};
        my $id = $body->{id};

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $s3_config = $self->_s3_config;

        unless (Purl::Storage::S3->config_is_usable($s3_config)) {
            $self->render_error($c, 'S3 not configured: bucket, access key, and secret key are required', 400);
            return;
        }

        my $result = $self->storage->upload_backup_to_s3($id, $s3_config);

        $c->render(json => {
            status => 'ok',
            upload => $result,
        });
    });
}

sub get_s3_config {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        my $s = $self->settings;
        my $s3 = {
            enabled         => $s ? $s->get('backup', 's3_enabled')  // 0 : 0,
            bucket          => $s ? $s->get('backup', 's3_bucket')   // '' : '',
            region          => $s ? $s->get('backup', 's3_region')   // 'us-east-1' : 'us-east-1',
            prefix          => $s ? $s->get('backup', 's3_prefix')   // 'purl-backups/' : 'purl-backups/',
            endpoint        => $s ? $s->get('backup', 's3_endpoint') // '' : '',
            has_credentials => ($ENV{AWS_ACCESS_KEY_ID} || ($s && $s->get('backup', 's3_access_key'))) ? 1 : 0,
            from_env        => $ENV{PURL_BACKUP_S3_ENABLED} ? 1 : 0,
            from_env_keys   => $self->env_flags('backup'),   # see get_schedule
        };

        $c->render(json => { s3 => $s3 });
    });
}

sub update_s3_config {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) } // {};

        # Same story as update_schedule: PURL_BACKUP_S3_ENABLED was the only
        # thing checked, so an edit to a bucket/region/prefix/endpoint pinned by
        # its own env var — or to credentials pinned by AWS_ACCESS_KEY_ID /
        # AWS_SECRET_ACCESS_KEY — reported success and changed nothing.
        return if $self->reject_env_managed($c, 'backup', $body);

        for my $key (qw(s3_enabled s3_bucket s3_region s3_prefix s3_endpoint s3_access_key s3_secret_key)) {
            if (defined $body->{$key}) {
                $self->settings->set('backup', $key, $body->{$key});
            }
        }

        $c->render(json => {
            status  => 'ok',
            message => 'S3 backup settings saved',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Backup - Backup management endpoints

=head1 DESCRIPTION

Handles backup list, create, restore, and delete operations.

=cut

package Purl::API::Controller::Backup;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

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

        my $body = eval { decode_json($c->req->body) } // {};
        my $id = $body->{id};

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $result = $self->storage->restore_backup($id);

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

        my $id = $c->param('id');

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $result = $self->storage->delete_backup($id);

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
        };

        $c->render(json => { schedule => $schedule });
    });
}

sub update_schedule {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        if ($ENV{PURL_BACKUP_SCHEDULE_ENABLED}) {
            $self->render_error($c, 'Cannot modify - configured via environment variable', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) } // {};

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

        my $body = eval { decode_json($c->req->body) } // {};
        my $id = $body->{id};

        unless ($id) {
            $self->render_error($c, 'Backup ID required', 400);
            return;
        }

        my $s = $self->settings;
        my $s3_config = {
            bucket     => $ENV{PURL_BACKUP_S3_BUCKET}     // ($s ? $s->get('backup', 's3_bucket')     : ''),
            region     => $ENV{PURL_BACKUP_S3_REGION}      // ($s ? $s->get('backup', 's3_region')     : 'us-east-1'),
            prefix     => $ENV{PURL_BACKUP_S3_PREFIX}      // ($s ? $s->get('backup', 's3_prefix')     : 'purl-backups/'),
            access_key => $ENV{AWS_ACCESS_KEY_ID}           // ($s ? $s->get('backup', 's3_access_key') : ''),
            secret_key => $ENV{AWS_SECRET_ACCESS_KEY}       // ($s ? $s->get('backup', 's3_secret_key') : ''),
            endpoint   => $ENV{PURL_BACKUP_S3_ENDPOINT}    // ($s ? $s->get('backup', 's3_endpoint')   : ''),
        };

        unless ($s3_config->{bucket} && $s3_config->{access_key} && $s3_config->{secret_key}) {
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
        };

        $c->render(json => { s3 => $s3 });
    });
}

sub update_s3_config {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'backup');

        if ($ENV{PURL_BACKUP_S3_ENABLED}) {
            $self->render_error($c, 'Cannot modify - configured via environment variable', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) } // {};

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

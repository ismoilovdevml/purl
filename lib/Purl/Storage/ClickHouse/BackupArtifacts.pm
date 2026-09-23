package Purl::Storage::ClickHouse::BackupArtifacts;
use Moo::Role;
use strict;
use warnings;
use 5.024;

use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(strftime);
use Purl::Util::TarStream qw(write_tar_gz extract_tar_gz);

# A backup's files wherever they live — the local CSV directory, its tar.gz
# archive, the S3 object — and their lifecycle: materialise for restore,
# archive for download/upload, upload to S3, delete, retention cleanup.
# Consumed by Purl::Storage::ClickHouse::Backup (metadata, export, import).

# Materialise a backup's CSV directory on local disk, wherever it actually
# lives. Returns ($dir, $tempdir_or_undef); the caller must keep the second
# value alive for as long as it uses the first (File::Temp cleans on scope
# exit).
#
# This is THE fix for "backups uploaded to S3 can never be restored": once
# upload_backup_to_s3 rewrote target_path to `s3://...`, every consumer tested
# it with `-d`, which is false for an S3 URI, so restore/delete/cleanup all
# gave up.
sub _materialize_backup_dir {
    my ($self, $backup, $s3_config) = @_;

    # Prefer the local copy when it is still on disk — no download needed.
    for my $candidate ($backup->{local_path}, $backup->{target_path}) {
        next unless $candidate && $candidate !~ m{^s3://};
        return ($candidate, undef) if -d $candidate;
    }

    require Purl::Storage::S3;
    my $uri = Purl::Storage::S3->parse_uri($backup->{target_path});

    unless ($uri) {
        die "Backup directory not found: " . ($backup->{target_path} // '');
    }

    die "Backup lives in S3 but S3 is not configured (bucket/access key/secret key)"
        unless $s3_config && $s3_config->{bucket}
            && $s3_config->{access_key} && $s3_config->{secret_key};

    my $s3 = $self->_s3_client($s3_config);
    my $tmp = tempdir(CLEANUP => 1);
    my $archive = File::Spec->catfile($tmp, 'backup.tar.gz');

    $s3->download_file(
        s3_key    => $self->_s3_key_for($backup, $s3_config),
        dest_path => $archive,
    );

    my $extract_dir = File::Spec->catdir($tmp, 'extracted');
    make_path($extract_dir);

    # Streams each member through a fixed buffer. The old loop asked
    # Archive::Tar for get_content, i.e. the whole of logs.csv in one scalar —
    # a multi-GB backup OOM-killed the worker on restore.
    extract_tar_gz($archive, $extract_dir, accept => sub {
        my ($name) = @_;
        # Flatten: archives are created from a flat directory, and refusing
        # nested paths keeps a crafted archive from writing outside $tmp.
        $name =~ s{^.*/}{};
        return undef unless $name =~ /^[\w\-]+\.csv$/;
        return $name;
    });

    unlink $archive;
    return ($extract_dir, $tmp);
}

sub create_backup_archive {
    my ($self, $id) = @_;

    my $backup = $self->get_backup($id);
    die "Backup not found" unless $backup;
    die "Backup not completed" unless $backup->{status} eq 'completed';

    # The LOCAL directory, not target_path — target_path becomes an s3:// URI
    # once the backup has been uploaded.
    my $path = $backup->{local_path} || $backup->{target_path};
    die "Backup directory not found: $path" unless $path && -d $path;

    my $archive_path = "${path}.tar.gz";

    # Reuse recent archive if it exists (less than 15 min old)
    if (-f $archive_path && -M $archive_path < 0.01) {
        return $archive_path;
    }

    my @entries;
    opendir(my $dh, $path) or die "Cannot open $path: $!";
    while (my $file = readdir($dh)) {
        next if $file =~ /^\./;
        my $full = File::Spec->catfile($path, $file);
        next unless -f $full;
        push @entries, { name => $file, path => $full };
    }
    closedir($dh);

    # Sorted so an archive is byte-identical for identical inputs; readdir
    # order is not.
    @entries = sort { $a->{name} cmp $b->{name} } @entries;

    # write_tar_gz streams every member through a 64 KiB buffer. The old code
    # slurped each CSV into a scalar and handed it to Archive::Tar::add_data,
    # which is why downloading a large backup could OOM-kill the worker.
    write_tar_gz($archive_path, \@entries);

    return $archive_path;
}

# Build an S3 client from a config hashref. One constructor for every S3
# operation so defaults (region/prefix/endpoint) cannot drift between upload,
# restore and delete.
sub _s3_client {
    my ($self, $s3_config) = @_;
    require Purl::Storage::S3;
    return Purl::Storage::S3->new(
        bucket     => $s3_config->{bucket},
        region     => $s3_config->{region}     // 'us-east-1',
        access_key => $s3_config->{access_key},
        secret_key => $s3_config->{secret_key},
        prefix     => $s3_config->{prefix}     // 'purl-backups/',
        endpoint   => $s3_config->{endpoint}   // '',
    );
}

# The object key (relative to the client's prefix) for a stored backup.
# Derived from the recorded s3:// URI when there is one, so a backup uploaded
# under an old prefix is still reachable after the prefix setting changes.
sub _s3_key_for {
    my ($self, $backup, $s3_config) = @_;

    require Purl::Storage::S3;
    my $uri = Purl::Storage::S3->parse_uri($backup->{target_path} // '');
    return "$backup->{id}.tar.gz" unless $uri;

    my $prefix = $s3_config->{prefix} // 'purl-backups/';
    my $key = $uri->{key};
    $key =~ s/^\Q$prefix\E//;
    return $key;
}

# Remove every artefact of a backup: local CSV directory, local archive, and
# the remote object. Local removal is confined to paths under /backups/ so a
# corrupted metadata row can never make this delete something else.
sub _purge_backup_artifacts {
    my ($self, $backup, $s3_config) = @_;

    for my $dir (grep { $_ } ($backup->{local_path}, $backup->{target_path})) {
        next if $dir =~ m{^s3://};
        next unless $dir =~ m{/backups/};
        remove_tree($dir) if -d $dir;
        my $archive = "${dir}.tar.gz";
        unlink $archive if -f $archive;
    }

    require Purl::Storage::S3;
    return 1 unless Purl::Storage::S3->parse_uri($backup->{target_path} // '');

    unless ($s3_config && $s3_config->{bucket}
            && $s3_config->{access_key} && $s3_config->{secret_key}) {
        # Deleting the metadata row while the object survives would orphan it
        # forever — the caller must be told.
        die "Backup is stored in S3 but S3 is not configured — cannot delete the remote object";
    }

    $self->_s3_client($s3_config)->delete_object(
        s3_key => $self->_s3_key_for($backup, $s3_config),
    );
    return 1;
}

sub cleanup_old_backups {
    my ($self, $retention_days, %opts) = @_;
    $retention_days //= 30;

    my $db = $self->database;
    my $cutoff = strftime('%Y-%m-%d %H:%M:%S', localtime(time() - $retention_days * 86400));
    my $safe_cutoff = $self->_quote_string($cutoff);

    my $old_backups = $self->_crud_read(qq{
        SELECT id, target_path, local_path
        FROM ${db}.backups
        WHERE status = 'completed'
          AND created_at < parseDateTimeBestEffort($safe_cutoff)
        ORDER BY created_at ASC
    });

    my $deleted = 0;
    for my $backup (@$old_backups) {
        eval {
            $self->_purge_backup_artifacts($backup, $opts{s3_config});

            my $safe_id = $self->_quote_string($backup->{id});
            $self->_crud_write("ALTER TABLE ${db}.backups DELETE WHERE id = $safe_id");
            $deleted++;
        };
        warn "Failed to clean backup $backup->{id}: $@" if $@;
    }

    return $deleted;
}

sub upload_backup_to_s3 {
    my ($self, $id, $s3_config) = @_;

    my $archive_path = $self->create_backup_archive($id);
    my $backup = $self->get_backup($id);
    my $local_path = ($backup && ($backup->{local_path} || $backup->{target_path})) // '';

    my $s3_key = "${id}.tar.gz";
    my $s3_uri = $self->_s3_client($s3_config)->upload_file(
        file_path => $archive_path,
        s3_key    => $s3_key,
    );

    # Update backup metadata. local_path is preserved EXPLICITLY: overwriting
    # target_path used to be the only record of where the backup lived, so an
    # upload made the local directory unreachable — restore, delete and
    # retention cleanup all tested it with `-d`, which an s3:// URI never
    # satisfies. Result: S3 backups could not be restored and local disk grew
    # forever.
    my $db = $self->database;
    my $safe_id    = $self->_quote_string($id);
    my $safe_path  = $self->_quote_string($s3_uri);
    my $safe_local = $self->_quote_string($local_path);
    $self->_crud_write(qq{
        ALTER TABLE ${db}.backups UPDATE
            target_type = 's3',
            target_path = $safe_path,
            local_path  = $safe_local
        WHERE id = $safe_id
    });

    return {
        id          => $id,
        target_type => 's3',
        target_path => $s3_uri,
        local_path  => $local_path,
    };
}

sub delete_backup {
    my ($self, $id, %opts) = @_;

    my $backup = $self->get_backup($id);
    die "Backup not found" unless $backup;

    $self->_purge_backup_artifacts($backup, $opts{s3_config});

    my $db = $self->database;
    my $safe_id = $self->_quote_string($id);
    $self->_crud_write("ALTER TABLE ${db}.backups DELETE WHERE id = $safe_id");

    return { status => 'deleted', id => $id };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::BackupArtifacts - a backup's local directory,
tar.gz archive and S3 object: materialise, archive, upload, delete and
retention cleanup. See L<Purl::Storage::ClickHouse::Backup> for the storage
targets and memory model.

=cut

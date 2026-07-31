package Purl::Storage::ClickHouse::Backup;
use Moo::Role;
use strict;
use warnings;
use 5.024;

use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(strftime);
use Purl::Util::TarStream qw(write_tar_gz extract_tar_gz);

my @BACKUP_TABLES = qw(logs alerts saved_searches audit_logs log_patterns);

my %VALID_BACKUP_TABLES = map { $_ => 1 } @BACKUP_TABLES;

# Export/import settings. Deliberately NOT `no_settings => 1`: that used to
# strip max_execution_time too, so a runaway export had no timeout at all.
# max_rows_to_read=0 lifts only the row cap (a full-table dump legitimately
# reads every row); the timeout stays, and is tunable for very large tables.
sub _backup_query_settings {
    my ($self) = @_;
    my $timeout = $ENV{PURL_BACKUP_QUERY_TIMEOUT} // 3600;
    $timeout = 3600 unless $timeout =~ /^\d+$/ && $timeout > 0;
    return "max_execution_time=$timeout&max_rows_to_read=0";
}

sub _validate_backup_table {
    my ($self, $table) = @_;
    return $VALID_BACKUP_TABLES{$table} ? 1 : 0;
}

sub _init_backup_schema {
    my ($self) = @_;
    my $db = $self->database;

    $self->_query(qq{
        CREATE TABLE IF NOT EXISTS ${db}.backups (
            id String,
            name String,
            target_type LowCardinality(String) DEFAULT 'local',
            target_path String DEFAULT '',
            local_path String DEFAULT '',
            status LowCardinality(String) DEFAULT 'pending',
            tables_backed_up String DEFAULT '',
            size_bytes UInt64 DEFAULT 0,
            rows_total UInt64 DEFAULT 0,
            error String DEFAULT '',
            created_at DateTime DEFAULT now(),
            completed_at DateTime DEFAULT toDateTime(0)
        )
        ENGINE = @{[$self->_engine_mergetree('backups')]}
        ORDER BY created_at
    });

    # Migration for instances created before local_path existed. Without it,
    # uploading a backup to S3 overwrote target_path and the local directory
    # became unreachable — un-deletable AND un-restorable.
    eval {
        $self->_query(qq{
            ALTER TABLE ${db}.backups ADD COLUMN IF NOT EXISTS local_path String DEFAULT ''
        });
    };
    warn "backups.local_path migration failed: $@" if $@;

    return 1;
}

sub list_backups {
    my ($self) = @_;
    my $db = $self->database;

    return $self->_crud_read(qq{
        SELECT
            id, name, target_type, target_path, local_path, status, tables_backed_up,
            size_bytes, rows_total, error,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%S') || 'Z' as created_at,
            if(completed_at = toDateTime(0), '',
               formatDateTime(completed_at, '%Y-%m-%dT%H:%i:%S') || 'Z') as completed_at
        FROM ${db}.backups
        ORDER BY created_at DESC
        LIMIT 100
    });
}

sub get_backup {
    my ($self, $id) = @_;

    return undef unless $id && $id =~ /^[\w\-]+$/;

    my $db = $self->database;
    my $safe_id = $self->_quote_string($id);

    my $result = $self->_crud_read(qq{
        SELECT
            id, name, target_type, target_path, local_path, status, tables_backed_up,
            size_bytes, rows_total, error,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%S') || 'Z' as created_at,
            if(completed_at = toDateTime(0), '',
               formatDateTime(completed_at, '%Y-%m-%dT%H:%i:%S') || 'Z') as completed_at
        FROM ${db}.backups
        WHERE id = $safe_id
        LIMIT 1
    });

    return $result->[0];
}

sub create_backup {
    my ($self, %params) = @_;

    my $name = $params{name} // 'backup_' . strftime('%Y%m%d_%H%M%S', localtime);
    $name =~ s/[^\w\-]/_/g;

    my $backup_dir = $params{backup_dir} // '/app/backups';
    my $id = $name . '_' . sprintf('%08x', time() & 0xFFFFFFFF);
    my $target_path = File::Spec->catdir($backup_dir, $id);
    my $db = $self->database;

    make_path($target_path);

    my $safe_id   = $self->_quote_string($id);
    my $safe_name = $self->_quote_string($name);
    my $safe_path = $self->_quote_string($target_path);

    $self->_crud_write(qq{
        INSERT INTO ${db}.backups (id, name, target_type, target_path, local_path, status)
        VALUES ($safe_id, $safe_name, 'local', $safe_path, $safe_path, 'running')
    });

    my $total_size = 0;
    my $total_rows = 0;
    my @backed_up;

    eval {
        for my $table (@BACKUP_TABLES) {
            unless ($self->_validate_backup_table($table)) {
                warn "Skipping invalid table name: $table";
                next;
            }
            my $safe_table_name = "`${table}`";
            my $full_table = "`${db}`.${safe_table_name}";

            my $safe_db    = $self->_quote_string($db);
            my $safe_table_str = $self->_quote_string($table);
            my $exists = $self->_query_json(qq{
                SELECT count() as cnt FROM system.tables
                WHERE database = $safe_db AND name = $safe_table_str
            });
            next unless $exists->[0] && $exists->[0]{cnt} > 0;

            # Ask the server for the row count instead of counting newlines in
            # the export: a CSV field may legally contain a newline, so the old
            # `() = $csv =~ /\n/g` under-reported every backup containing a
            # multi-line log message.
            my $counted = $self->_query_json("SELECT count() as cnt FROM $full_table",
                no_cache => 1);
            my $rows = $counted->[0] ? ($counted->[0]{cnt} // 0) : 0;

            my $file = File::Spec->catfile($target_path, "${table}.csv");

            # Stream the export straight to disk. The previous implementation
            # read the ENTIRE table into one Perl scalar, which OOM-kills the
            # worker on any real logs table.
            my $bytes = $self->_query_to_file(
                "SELECT * FROM $full_table",
                $file,
                format   => 'CSVWithNames',
                settings => $self->_backup_query_settings,
            );

            unless ($bytes && $bytes > 0) {
                unlink $file;
                next;
            }

            $total_size += (-s $file || 0);
            $total_rows += $rows;

            push @backed_up, $table;
        }

        my $tables_str = $self->_quote_string(join(',', @backed_up));
        $self->_crud_write(qq{
            ALTER TABLE ${db}.backups UPDATE
                status = 'completed',
                tables_backed_up = $tables_str,
                size_bytes = $total_size,
                rows_total = $total_rows,
                completed_at = now()
            WHERE id = $safe_id
        });
    };

    if ($@) {
        my $err = "$@";
        my $safe_err = $self->_quote_string($err);
        eval {
            $self->_crud_write(qq{
                ALTER TABLE ${db}.backups UPDATE
                    status = 'failed', error = $safe_err
                WHERE id = $safe_id
            });
        };
        die "Backup failed: $err";
    }

    return {
        id          => $id,
        name        => $name,
        target_path => $target_path,
        tables      => \@backed_up,
        size_bytes  => $total_size,
        rows_total  => $total_rows,
        status      => 'completed',
    };
}

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

# mode => 'append' (default) inserts on top of whatever is there.
# mode => 'replace' TRUNCATEs each restored table first, which makes restore
#         idempotent — running it twice used to double every row.
sub restore_backup {
    my ($self, $id, %opts) = @_;

    my $mode = $opts{mode} // 'append';
    die "Invalid restore mode: $mode (expected 'append' or 'replace')"
        unless $mode eq 'append' || $mode eq 'replace';

    my $backup = $self->get_backup($id);
    die "Backup not found" unless $backup;
    die "Backup status is $backup->{status}, expected completed"
        unless $backup->{status} eq 'completed';

    my ($path, $tmp_guard) = $self->_materialize_backup_dir($backup, $opts{s3_config});

    my $db = $self->database;
    my @restored;
    my $total_rows = 0;

    for my $table (@BACKUP_TABLES) {
        my $file = File::Spec->catfile($path, "${table}.csv");
        next unless -f $file && -s $file > 10;

        my $full_table = "`${db}`.`${table}`";

        if ($mode eq 'replace') {
            $self->_query("TRUNCATE TABLE IF EXISTS $full_table");
        }

        # Streams the file from disk — a restore is not bounded by RAM.
        my $response = $self->_post_file(
            "INSERT INTO $full_table FORMAT CSVWithNames",
            $file,
            settings => $self->_backup_query_settings,
        );

        # Exact count from the server when it reports one; otherwise fall back
        # to counting CSV lines (approximate for quoted embedded newlines,
        # which is what the old implementation always did).
        my $written = $self->_written_rows($response) // _csv_data_rows($file);
        $total_rows += $written;
        push @restored, $table;
    }

    return {
        backup_id => $id,
        tables    => \@restored,
        rows      => $total_rows,
        mode      => $mode,
        status    => 'completed',
    };
}

# Count CSV data rows without loading the file: read in fixed blocks and
# subtract the header line.
sub _csv_data_rows {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return 0;
    my $lines = 0;
    my $buffer;
    while (read $fh, $buffer, 262_144) {
        $lines += ($buffer =~ tr/\n//);
    }
    close $fh;
    return $lines > 0 ? $lines - 1 : 0;
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

Purl::Storage::ClickHouse::Backup - Backup and restore operations for ClickHouse

=head1 DESCRIPTION

Moo::Role providing backup/restore via CSV export/import through the ClickHouse HTTP API.
Tracks backup metadata in the C<purl.backups> table.

=head1 STORAGE TARGETS

A backup always starts as a directory of CSV files on local disk
(C<local_path>). Uploading it to S3 sets C<target_type> to C<s3> and
C<target_path> to the C<s3://> URI while B<preserving> C<local_path>, so
restore, delete and retention cleanup can find both copies. Restoring a
backup whose local directory is gone downloads and extracts the archive into
a temporary directory first.

=head1 MEMORY

Nothing here is bounded by archive or table size.

Export streams the ClickHouse response directly to disk; restore streams the
CSV file directly into the HTTP request body; C<create_backup_archive> and the
extraction inside C<_materialize_backup_dir> stream through
L<Purl::Util::TarStream>, which holds at most 64 KiB of member data at a time.

Archive::Tar used to be the exception: writing needed the whole of each CSV in
a scalar (C<add_data>) and reading needed the same (C<get_content>), so a
multi-GB C<logs.csv> OOM-killed the worker on download and on restore. It is no
longer used. Archives stay POSIX ustar, so previously written archives still
extract and ordinary C<tar> still reads ours.

=head1 RESTORE MODES

    $storage->restore_backup($id);                      # append (default)
    $storage->restore_backup($id, mode => 'replace');   # TRUNCATE, then insert

C<replace> makes restore idempotent. C<append> re-inserts every row, so
running it twice doubles the data — it exists only for merging a backup into
a live table on purpose.

=head1 ENVIRONMENT

    PURL_BACKUP_QUERY_TIMEOUT - max_execution_time (seconds) for export and
                                restore queries. Default 3600.

=cut

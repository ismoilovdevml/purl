package Purl::Storage::ClickHouse::Backup;
use Moo::Role;
use strict;
use warnings;
use 5.024;

use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);

# Where a backup's files live (local directory, tar.gz archive, S3 object) and
# their lifecycle — materialise, archive, upload, delete, retention — is
# Purl::Storage::ClickHouse::BackupArtifacts. This role owns the metadata
# table, the export (create_backup) and the import (restore_backup).
with 'Purl::Storage::ClickHouse::BackupArtifacts';

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

# mode => 'append' (default) inserts on top of whatever is there.
# mode => 'replace' TRUNCATEs each restored table first, which makes restore
#         idempotent — running it twice used to double every row.
sub restore_backup {
    my ($self, $id, %opts) = @_;

    my $mode = $opts{mode} // 'append';
    die "Invalid restore mode: $mode (expected 'append' or 'replace')\n"
        unless $mode eq 'append' || $mode eq 'replace';

    my $backup = $self->get_backup($id);
    die "Backup not found\n" unless $backup;
    die "Backup status is $backup->{status}, expected completed\n"
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

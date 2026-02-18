package Purl::Storage::ClickHouse::Backup;
use Moo::Role;
use strict;
use warnings;
use 5.024;

use File::Path qw(make_path remove_tree);
use File::Spec;
use POSIX qw(strftime);
use URI::Escape qw(uri_escape);

my @BACKUP_TABLES = qw(logs alerts saved_searches audit_logs log_patterns);

my %VALID_BACKUP_TABLES = map { $_ => 1 } @BACKUP_TABLES;

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
}

sub list_backups {
    my ($self) = @_;
    my $db = $self->database;

    return $self->_query_json(qq{
        SELECT
            id, name, target_type, target_path, status, tables_backed_up,
            size_bytes, rows_total, error,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%S') || 'Z' as created_at,
            if(completed_at = toDateTime(0), '',
               formatDateTime(completed_at, '%Y-%m-%dT%H:%i:%S') || 'Z') as completed_at
        FROM ${db}.backups
        ORDER BY created_at DESC
        LIMIT 100
    }, no_cache => 1);
}

sub get_backup {
    my ($self, $id) = @_;

    return undef unless $id && $id =~ /^[\w\-]+$/;

    my $db = $self->database;
    my $safe_id = $self->_quote_string($id);

    my $result = $self->_query_json(qq{
        SELECT
            id, name, target_type, target_path, status, tables_backed_up,
            size_bytes, rows_total, error,
            formatDateTime(created_at, '%Y-%m-%dT%H:%i:%S') || 'Z' as created_at,
            if(completed_at = toDateTime(0), '',
               formatDateTime(completed_at, '%Y-%m-%dT%H:%i:%S') || 'Z') as completed_at
        FROM ${db}.backups
        WHERE id = $safe_id
        LIMIT 1
    }, no_cache => 1);

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

    $self->_query(qq{
        INSERT INTO ${db}.backups (id, name, target_type, target_path, status)
        VALUES ($safe_id, $safe_name, 'local', $safe_path, 'running')
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

            my $csv = $self->_query(
                "SELECT * FROM $full_table",
                format      => 'CSVWithNames',
                no_settings => 1,
            );
            next unless $csv && length($csv) > 0;

            my $file = File::Spec->catfile($target_path, "${table}.csv");
            open my $fh, '>:raw', $file or die "Cannot write $file: $!";
            print $fh $csv;
            close $fh;

            my $size = -s $file || 0;
            $total_size += $size;

            my $rows = () = $csv =~ /\n/g;
            $rows = $rows > 0 ? $rows - 1 : 0;
            $total_rows += $rows;

            push @backed_up, $table;
        }

        my $tables_str = $self->_quote_string(join(',', @backed_up));
        $self->_query(qq{
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
            $self->_query(qq{
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

sub restore_backup {
    my ($self, $id) = @_;

    my $backup = $self->get_backup($id);
    die "Backup not found" unless $backup;
    die "Backup status is $backup->{status}, expected completed"
        unless $backup->{status} eq 'completed';

    my $path = $backup->{target_path};
    die "Backup directory not found: $path" unless -d $path;

    my $db = $self->database;
    my @restored;
    my $total_rows = 0;

    for my $table (@BACKUP_TABLES) {
        my $file = File::Spec->catfile($path, "${table}.csv");
        next unless -f $file && -s $file;

        open my $fh, '<:raw', $file or die "Cannot read $file: $!";
        local $/;
        my $csv = <$fh>;
        close $fh;

        next unless $csv && length($csv) > 10;

        my $full_table = "`${db}`.`${table}`";
        my $url = $self->_base_url . '/?' . $self->_auth_params;
        $url .= '&query=' . uri_escape("INSERT INTO $full_table FORMAT CSVWithNames");

        my $response = $self->_http->post($url, {
            content => $csv,
            headers => { 'Content-Type' => 'text/csv' },
        });

        unless ($response->{success}) {
            die "Restore failed for $table: $response->{status} - $response->{content}";
        }

        my $rows = () = $csv =~ /\n/g;
        $rows = $rows > 0 ? $rows - 1 : 0;
        $total_rows += $rows;
        push @restored, $table;
    }

    return {
        backup_id => $id,
        tables    => \@restored,
        rows      => $total_rows,
        status    => 'completed',
    };
}

sub delete_backup {
    my ($self, $id) = @_;

    my $backup = $self->get_backup($id);
    die "Backup not found" unless $backup;

    if ($backup->{target_path} && -d $backup->{target_path}) {
        die "Invalid backup path" unless $backup->{target_path} =~ m{/backups/};
        remove_tree($backup->{target_path});
    }

    my $db = $self->database;
    my $safe_id = $self->_quote_string($id);
    $self->_query("ALTER TABLE ${db}.backups DELETE WHERE id = $safe_id");

    return { status => 'deleted', id => $id };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Backup - Backup and restore operations for ClickHouse

=head1 DESCRIPTION

Moo::Role providing backup/restore via CSV export/import through the ClickHouse HTTP API.
Tracks backup metadata in the C<purl.backups> table.

=cut

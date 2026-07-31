#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# Backup lifecycle regressions.
#
# THE BUG: upload_backup_to_s3 overwrote target_path with an `s3://...` URI,
# and every consumer then tested that path with `-d`:
#
#   restore_backup      die "Backup directory not found" unless -d $path
#   delete_backup       if (... -d $backup->{target_path})
#   cleanup_old_backups if (... -d $backup->{target_path})
#
# `-d "s3://bucket/x.tar.gz"` is never true, so once a backup was uploaded it
# could not be restored, its local directory was never deleted, and retention
# never reclaimed a byte of disk.
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use Purl::Storage::S3;

# --- Fake S3 client ---------------------------------------------------------
{
    package FakeS3;
    sub new {
        my ($class, %args) = @_;
        return bless { archive => $args{archive}, deleted => [], uploaded => [],
                       downloads => 0, fail_download => $args{fail_download} }, $class;
    }
    sub download_file {
        my ($self, %args) = @_;
        $self->{downloads}++;
        die "S3 download failed: 404" if $self->{fail_download};
        open my $in,  '<:raw', $self->{archive} or die "no source archive: $!";
        open my $out, '>:raw', $args{dest_path} or die "cannot write $args{dest_path}: $!";
        local $/;
        print {$out} <$in>;
        close $in;
        close $out;
        return $args{dest_path};
    }
    sub delete_object { push @{ $_[0]->{deleted} }, $_[2]; return 1 }
    sub upload_file   {
        my ($self, %args) = @_;
        push @{ $self->{uploaded} }, \%args;
        return "s3://test-bucket/purl-backups/$args{s3_key}";
    }
}

# --- Storage class consuming the Backup role -------------------------------
{
    package FakeBackupStorage;
    use Moo;

    has 'database'    => (is => 'ro', default => sub { 'purl' });
    has 'rows'        => (is => 'rw', default => sub { {} });   # backup id => row
    has 'queries'     => (is => 'ro', default => sub { [] });
    has 'exports'     => (is => 'ro', default => sub { [] });
    has 'inserts'     => (is => 'ro', default => sub { [] });
    has 's3'          => (is => 'rw', default => sub { undef });
    has 'table_rows'  => (is => 'rw', default => sub { 7 });

    with 'Purl::Storage::ClickHouse::Backup';

    sub _quote_string { my (undef, $v) = @_; $v //= ''; $v =~ s/'/\\'/g; return "'$v'" }
    sub _engine_mergetree { return 'MergeTree()' }

    sub _query {
        my ($self, $sql, %opts) = @_;
        push @{ $self->queries }, $sql;
        return '';
    }

    sub _query_json {
        my ($self, $sql, %opts) = @_;
        push @{ $self->queries }, $sql;
        return [{ cnt => $self->table_rows }] if $sql =~ /count\(\)/;
        if ($sql =~ /FROM purl\.backups/) {
            my ($id) = $sql =~ /WHERE id = '([^']+)'/;
            return [ $self->rows->{$id} ] if $id && $self->rows->{$id};
            return [ values %{ $self->rows } ];
        }
        return [];
    }

    sub _query_to_file {
        my ($self, $sql, $file, %opts) = @_;
        push @{ $self->exports }, { sql => $sql, file => $file, opts => \%opts };
        open my $fh, '>:raw', $file or die $!;
        print {$fh} "id,message\n1,hello\n2,world\n";
        close $fh;
        return 26;
    }

    sub _post_file {
        my ($self, $sql, $file, %opts) = @_;
        push @{ $self->inserts }, { sql => $sql, file => $file };
        return { success => 1, status => 200, content => '',
                 headers => { 'x-clickhouse-summary' => '{"written_rows":"2"}' } };
    }

    sub _written_rows {
        my ($self, $response) = @_;
        my $summary = $response->{headers}{'x-clickhouse-summary'} // return undef;
        my ($rows) = $summary =~ /"written_rows"\s*:\s*"?(\d+)/;
        return $rows;
    }

    # Override the role's constructor so tests inject a fake client.
    sub _s3_client { return $_[0]->s3 }
}

# --- Helpers ----------------------------------------------------------------

# A real .tar.gz containing one CSV, so the restore path exercises genuine
# extraction rather than a stub.
sub _make_archive {
    my ($dir) = @_;
    require Archive::Tar;
    my $tar = Archive::Tar->new();
    $tar->add_data('logs.csv', "id,message\n1,hello\n2,world\n");
    my $path = File::Spec->catfile($dir, 'src.tar.gz');
    $tar->write($path, Archive::Tar::COMPRESS_GZIP());
    return $path;
}

sub _local_backup_dir {
    my ($root, $id) = @_;
    my $dir = File::Spec->catdir($root, 'backups', $id);
    make_path($dir);
    open my $fh, '>:raw', File::Spec->catfile($dir, 'logs.csv') or die $!;
    print {$fh} "id,message\n1,hello\n2,world\n";
    close $fh;
    return $dir;
}

my $s3_config = { bucket => 'test-bucket', access_key => 'k', secret_key => 's',
                  prefix => 'purl-backups/' };

# ===========================================================================
# RESTORE
# ===========================================================================
subtest 'restore_backup restores a backup that lives only in S3' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $archive = _make_archive($root);
    my $fake_s3 = FakeS3->new(archive => $archive);

    my $storage = FakeBackupStorage->new(s3 => $fake_s3);
    $storage->rows({
        b1 => {
            id => 'b1', status => 'completed',
            target_path => 's3://test-bucket/purl-backups/b1.tar.gz',
            local_path  => '/gone/backups/b1',
        },
    });

    my $result = $storage->restore_backup('b1', s3_config => $s3_config);

    is $fake_s3->{downloads}, 1, 'archive downloaded from S3';
    is_deeply $result->{tables}, ['logs'], 'logs table restored';
    is $result->{rows}, 2, 'row count from the server summary';
    is scalar @{ $storage->inserts }, 1, 'one INSERT issued';
    like $storage->inserts->[0]{sql}, qr/INSERT INTO `purl`\.`logs` FORMAT CSVWithNames/,
        'streams CSV into the right table';
};

subtest 'restore_backup prefers a surviving local copy over downloading' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir = _local_backup_dir($root, 'b2');
    my $fake_s3 = FakeS3->new(archive => _make_archive($root));

    my $storage = FakeBackupStorage->new(s3 => $fake_s3);
    $storage->rows({
        b2 => { id => 'b2', status => 'completed',
                target_path => 's3://test-bucket/purl-backups/b2.tar.gz',
                local_path  => $dir },
    });

    my $result = $storage->restore_backup('b2', s3_config => $s3_config);
    is $fake_s3->{downloads}, 0, 'no download when the local directory is intact';
    is_deeply $result->{tables}, ['logs'], 'restored from disk';
};

subtest 'restore_backup mode=replace truncates first' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = _local_backup_dir($root, 'b3');
    my $storage = FakeBackupStorage->new;
    $storage->rows({ b3 => { id => 'b3', status => 'completed',
                             target_path => $dir, local_path => $dir } });

    my $result = $storage->restore_backup('b3', mode => 'replace');
    is $result->{mode}, 'replace', 'mode echoed back';
    ok scalar(grep { /TRUNCATE TABLE IF EXISTS `purl`\.`logs`/ } @{ $storage->queries }),
        'table truncated before insert — a repeated restore cannot double the rows';
};

subtest 'restore_backup default mode appends (no TRUNCATE)' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = _local_backup_dir($root, 'b4');
    my $storage = FakeBackupStorage->new;
    $storage->rows({ b4 => { id => 'b4', status => 'completed',
                             target_path => $dir, local_path => $dir } });

    my $result = $storage->restore_backup('b4');
    is $result->{mode}, 'append', 'defaults to append';
    ok !scalar(grep { /TRUNCATE/ } @{ $storage->queries }),
        'append never truncates — destructive behaviour must be explicit';
};

subtest 'restore_backup rejects an unknown mode' => sub {
    my $storage = FakeBackupStorage->new;
    my $ok = eval { $storage->restore_backup('b5', mode => 'obliterate'); 1 };
    ok !$ok, 'dies on an unknown mode';
    like $@, qr/Invalid restore mode/, 'names the problem';
};

subtest 'restore_backup of an S3 backup without S3 config fails loudly' => sub {
    my $storage = FakeBackupStorage->new;
    $storage->rows({
        b6 => { id => 'b6', status => 'completed',
                target_path => 's3://test-bucket/purl-backups/b6.tar.gz',
                local_path  => '/gone/backups/b6' },
    });

    my $ok = eval { $storage->restore_backup('b6'); 1 };
    ok !$ok, 'dies rather than pretending nothing was restored';
    like $@, qr/S3 is not configured/, 'explains what is missing';
};

subtest 'restore_backup refuses an incomplete backup' => sub {
    my $storage = FakeBackupStorage->new;
    $storage->rows({ b7 => { id => 'b7', status => 'failed', target_path => '/tmp/x' } });
    my $ok = eval { $storage->restore_backup('b7'); 1 };
    ok !$ok, 'dies for a non-completed backup';
    like $@, qr/expected completed/, 'explains why';
};

# ===========================================================================
# DELETE / CLEANUP
# ===========================================================================
subtest 'delete_backup removes the local directory AND the S3 object' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = _local_backup_dir($root, 'd1');
    my $archive = "${dir}.tar.gz";
    open my $fh, '>:raw', $archive or die $!;
    print {$fh} 'archive';
    close $fh;

    my $fake_s3 = FakeS3->new;
    my $storage = FakeBackupStorage->new(s3 => $fake_s3);
    $storage->rows({
        d1 => { id => 'd1', status => 'completed',
                target_path => 's3://test-bucket/purl-backups/d1.tar.gz',
                local_path  => $dir },
    });

    my $result = $storage->delete_backup('d1', s3_config => $s3_config);
    is $result->{status}, 'deleted', 'reports deletion';
    ok !-d $dir, 'local directory removed (it never was before this fix)';
    ok !-f $archive, 'local archive removed';
    is_deeply $fake_s3->{deleted}, ['d1.tar.gz'], 'remote object removed';
    ok scalar(grep { /ALTER TABLE purl\.backups DELETE/ } @{ $storage->queries }),
        'metadata row removed';
};

subtest 'delete_backup will not orphan an S3 object' => sub {
    my $storage = FakeBackupStorage->new;
    $storage->rows({
        d2 => { id => 'd2', status => 'completed',
                target_path => 's3://test-bucket/purl-backups/d2.tar.gz',
                local_path  => '' },
    });

    my $ok = eval { $storage->delete_backup('d2'); 1 };
    ok !$ok, 'dies instead of dropping the row and leaving the object behind';
    ok !scalar(grep { /ALTER TABLE purl\.backups DELETE/ } @{ $storage->queries }),
        'metadata row kept, so the object is still discoverable';
};

subtest 'delete_backup only removes paths under /backups/' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $outside = File::Spec->catdir($root, 'etc');
    make_path($outside);

    my $storage = FakeBackupStorage->new;
    $storage->rows({ d3 => { id => 'd3', status => 'completed',
                             target_path => $outside, local_path => $outside } });

    $storage->delete_backup('d3');
    ok -d $outside, 'a path outside /backups/ is left untouched';
};

subtest 'cleanup_old_backups reclaims local disk for uploaded backups' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = _local_backup_dir($root, 'old1');
    my $fake_s3 = FakeS3->new;

    my $storage = FakeBackupStorage->new(s3 => $fake_s3);
    $storage->rows({
        old1 => { id => 'old1', status => 'completed',
                  target_path => 's3://test-bucket/purl-backups/old1.tar.gz',
                  local_path  => $dir },
    });

    my $deleted = $storage->cleanup_old_backups(30, s3_config => $s3_config);
    is $deleted, 1, 'one backup cleaned';
    ok !-d $dir, 'local directory reclaimed (retention used to free nothing)';
    is_deeply $fake_s3->{deleted}, ['old1.tar.gz'], 'remote object removed too';
};

# ===========================================================================
# UPLOAD
# ===========================================================================
subtest 'upload_backup_to_s3 preserves the local path' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $dir  = _local_backup_dir($root, 'u1');

    my $fake_s3 = FakeS3->new;
    my $storage = FakeBackupStorage->new(s3 => $fake_s3);
    $storage->rows({ u1 => { id => 'u1', status => 'completed',
                             target_path => $dir, local_path => $dir } });

    my $result = $storage->upload_backup_to_s3('u1', $s3_config);
    is $result->{target_type}, 's3', 'marked as an S3 backup';
    is $result->{target_path}, 's3://test-bucket/purl-backups/u1.tar.gz', 'records the URI';
    is $result->{local_path}, $dir, 'local path retained';

    ok scalar(grep { /local_path\s*=\s*'\Q$dir\E'/ } @{ $storage->queries }),
        'local_path written to the metadata row, not silently dropped';
};

# ===========================================================================
# CREATE (streaming export)
# ===========================================================================
subtest 'create_backup streams each table to disk' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $storage = FakeBackupStorage->new(table_rows => 42);

    my $result = $storage->create_backup(
        name       => 'nightly',
        backup_dir => File::Spec->catdir($root, 'backups'),
    );

    ok scalar @{ $storage->exports } > 0, 'export went through _query_to_file';
    for my $export (@{ $storage->exports }) {
        like $export->{sql}, qr/^SELECT \* FROM/, 'exports the whole table';
        ok !$export->{opts}{no_settings},
            'does NOT disable query settings — that also removed max_execution_time';
        like $export->{opts}{settings}, qr/max_execution_time=\d+/,
            'export carries an explicit timeout';
        like $export->{opts}{settings}, qr/max_rows_to_read=0/,
            'only the row cap is lifted';
    }

    is $result->{status}, 'completed', 'backup completed';
    ok $result->{rows_total} > 0, 'row totals recorded';
};

subtest 'create_backup counts rows from the server, not from newlines' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $storage = FakeBackupStorage->new(table_rows => 1000);

    my $result = $storage->create_backup(
        name       => 'counted',
        backup_dir => File::Spec->catdir($root, 'backups'),
    );

    my $tables = scalar @{ $result->{tables} };
    is $result->{rows_total}, 1000 * $tables,
        'uses SELECT count() — a newline inside a quoted CSV field cannot skew it';
};

subtest 'create_backup records the local path' => sub {
    my $root = tempdir(CLEANUP => 1);
    my $storage = FakeBackupStorage->new;
    my $result = $storage->create_backup(
        name       => 'paths',
        backup_dir => File::Spec->catdir($root, 'backups'),
    );

    ok scalar(grep { /INSERT INTO purl\.backups .*local_path/s } @{ $storage->queries }),
        'local_path populated at creation time';
    ok -d $result->{target_path}, 'backup directory created';
};

done_testing();

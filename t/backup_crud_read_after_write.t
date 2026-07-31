#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Storage::ClickHouse;

# ============================================
# REGRESSION (#34): the backups table was skipped by the read-after-write
# conversion.
#
# alerts, saved searches, dashboards, pipelines and agents were moved onto
# _crud_write / _crud_read. Backup.pm was not, so it kept:
#
#   writes — async_insert with wait_for_async_insert=0 and ALTER ... UPDATE at
#            the default mutations_sync=0, i.e. a 200 OK did not mean the row
#            was visible; and
#   reads  — _query_json, which caches every SELECT for cache_ttl (5s) in a
#            PER-WORKER cache, so the worker answering the next poll had no way
#            of knowing about the write.
#
# Symptom: create a backup, and the backups list flickers for ~5 seconds while
# BackupSettings polls — the row appears, vanishes, reappears — and the
# running -> completed transition lags behind reality.
# ============================================

# ClickHouse stand-in that honours the async/sync settings carried in the URL.
{
    package FakeClickHouse;

    sub new {
        return bless {
            requests => [],
            visible  => {},   # id => row a SELECT can see
            pending  => {},   # id => row parked in the async insert buffer
        }, $_[0];
    }

    sub requests_matching {
        my ($self, $re) = @_;
        return grep { $_->{sql} =~ $re } @{ $self->{requests} };
    }

    sub request { my ($s, undef, $url, $opts) = @_; return $s->post($url, $opts) }

    sub post {
        my ($self, $url, $opts) = @_;
        my $sql = $opts->{content} // '';
        push @{ $self->{requests} }, { url => $url, sql => $sql };

        my $insert_is_sync   = $url =~ /async_insert=0/            ? 1 : 0;
        my $mutation_is_sync = $url =~ /mutations_sync=1/          ? 1 : 0;

        if ($sql =~ /INSERT\s+INTO\s+\S*\.backups\b.*?VALUES\s*\((.*)\)/is) {
            my @v = $1 =~ /'([^']*)'/g;
            my $row = {
                id           => $v[0] // '',
                name         => $v[1] // '',
                target_type  => $v[2] // 'local',
                target_path  => $v[3] // '',
                local_path   => $v[4] // '',
                status       => $v[5] // 'running',
                created_at   => '2026-07-31T00:00:00Z',
                completed_at => '',
            };
            my $bucket = $insert_is_sync ? 'visible' : 'pending';
            $self->{$bucket}{ $row->{id} } = $row;
        }
        elsif ($sql =~ /ALTER\s+TABLE\s+\S*\.backups\s+UPDATE(.*?)WHERE\s+id\s*=\s*'([^']*)'/is) {
            my ($set, $id) = ($1, $2);
            # mutations_sync=0 => applied in the background, i.e. not yet.
            if ($mutation_is_sync && $self->{visible}{$id}) {
                my ($status) = $set =~ /status\s*=\s*'([^']*)'/;
                $self->{visible}{$id}{status} = $status if $status;
            }
        }
        elsif ($sql =~ /ALTER\s+TABLE\s+\S*\.backups\s+DELETE\s+WHERE\s+id\s*=\s*'([^']*)'/is) {
            delete $self->{visible}{$1} if $mutation_is_sync;
        }

        my $content = '';
        if ($sql =~ /FROM\s+system\.tables/is) {
            $content = qq({"cnt":"0"}\n);       # no tables => nothing to export
        }
        elsif ($sql =~ /^\s*SELECT.*FROM\s+\S*\.backups/is) {
            my ($id) = $sql =~ /WHERE id = '([^']*)'/;
            my @rows = $id ? grep { $_->{id} eq $id } values %{ $self->{visible} }
                           : values %{ $self->{visible} };
            $content = join '', map {
                my $r = $_;
                '{' . join(',', map { qq("$_":") . $r->{$_} . '"' } sort keys %$r) . "}\n";
            } @rows;
        }

        return { success => 1, status => 200, content => $content, headers => {} };
    }
}

sub new_storage {
    return Purl::Storage::ClickHouse->new(
        host     => 'fake',
        port     => 8123,
        database => 'purl',
        _http    => FakeClickHouse->new,
    );
}

my $tmp = tempdir(CLEANUP => 1);

# ============================================
# Write path
# ============================================

subtest 'the backup row is inserted synchronously' => sub {
    my $s = new_storage();
    $s->create_backup(name => 'nightly', backup_dir => $tmp);

    my ($insert) = $s->_http->requests_matching(qr/INSERT INTO \S*\.backups/);
    ok $insert, 'an INSERT was issued';
    like $insert->{url}, qr/async_insert=0/,
        'the backup row does not ride the ingest async buffer';
    unlike $insert->{url}, qr/wait_for_async_insert=0/,
        'and does not inherit the fire-and-forget ingest settings';
    is scalar(keys %{ $s->_http->{pending} }), 0,
        'nothing left invisible in the async buffer';
};

subtest 'the running -> completed transition waits for the mutation' => sub {
    my $s = new_storage();
    $s->create_backup(name => 'nightly', backup_dir => $tmp);

    my ($update) = $s->_http->requests_matching(qr/ALTER TABLE \S*\.backups UPDATE/);
    ok $update, 'a status UPDATE was issued';
    like $update->{url}, qr/mutations_sync=1/,
        'status change is applied before the request returns';
};

subtest 'deleting a backup waits for the mutation' => sub {
    my $s = new_storage();
    my $created = $s->create_backup(name => 'doomed', backup_dir => $tmp);

    $s->delete_backup($created->{id});
    my ($del) = $s->_http->requests_matching(qr/ALTER TABLE \S*\.backups DELETE/);
    ok $del, 'an ALTER ... DELETE was issued';
    like $del->{url}, qr/mutations_sync=1/, 'delete waits for the mutation';
};

# ============================================
# Read path
# ============================================

subtest 'the backup list is never served from the per-worker query cache' => sub {
    my $s = new_storage();
    $s->create_backup(name => 'one', backup_dir => $tmp);
    @{ $s->_http->{requests} } = ();

    $s->list_backups for 1 .. 3;
    my @selects = $s->_http->requests_matching(qr/FROM purl\.backups/);
    is scalar(@selects), 3,
        'three list calls hit ClickHouse three times (a cached second call is a stale read)';
};

subtest 'get_backup is never served from the cache either' => sub {
    my $s = new_storage();
    my $created = $s->create_backup(name => 'polled', backup_dir => $tmp);
    @{ $s->_http->{requests} } = ();

    $s->get_backup($created->{id}) for 1 .. 3;
    my @selects = $s->_http->requests_matching(qr/FROM purl\.backups/);
    is scalar(@selects), 3, 'the status poll always reads through';
};

# ============================================
# End to end: create then immediately list
# ============================================

subtest 'a created backup is visible to the very next list, every time' => sub {
    my $s = new_storage();

    for my $i (1 .. 10) {
        $s->create_backup(name => "backup$i", backup_dir => $tmp);
        my $listed = $s->list_backups;
        is scalar(@$listed), $i, "iteration $i: list contains all $i backups";
    }
};

subtest 'the completed status is visible to the very next read' => sub {
    my $s = new_storage();
    my $created = $s->create_backup(name => 'statuscheck', backup_dir => $tmp);

    my $row = $s->get_backup($created->{id});
    ok $row, 'the row exists immediately after create';
    is $row->{status}, 'completed',
        'and already reports completed — not the stale "running" the UI used to poll on';
};

subtest 'a deleted backup disappears from the very next list' => sub {
    my $s = new_storage();
    my $created = $s->create_backup(name => 'gone', backup_dir => $tmp);
    is scalar(@{ $s->list_backups }), 1, 'created';

    $s->delete_backup($created->{id});
    is scalar(@{ $s->list_backups }), 0, 'delete is visible immediately';
};

done_testing();

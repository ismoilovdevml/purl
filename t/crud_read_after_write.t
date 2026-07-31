#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Storage::ClickHouse;

# ============================================
# Read-after-write for metadata (CRUD) tables.
#
# Reported symptom: GET /api/alerts polled at 0.4s intervals right after a
# create returned 1 1 1 1 1 0 1 1 0 1 0 1 1 1 ... — the new alert appeared,
# vanished, and reappeared for roughly five seconds.
#
# Two independent causes, both reproduced here against a ClickHouse stand-in
# that models exactly the two behaviours involved:
#
#   WRITE — the INSERT went out with async_insert=1&wait_for_async_insert=0
#           (the ingest fast path) and ALTER ... UPDATE/DELETE with the default
#           mutations_sync=0, so a 200 OK did not mean "visible to the next
#           SELECT".
#   READ  — _query_json caches EVERY SELECT for cache_ttl (5s, hence the ~5s
#           window) and, under prefork, each worker holds its own cache. The
#           worker that wrote could not invalidate the cache of the worker that
#           answers the next list request.
# ============================================

# A ClickHouse stand-in that honours the async/sync settings from the URL.
# Rows written with async_insert=1&wait_for_async_insert=0 land in a staging
# buffer and are NOT returned by SELECT until explicitly flushed — which is
# what the real server's async insert buffer does.
{
    package FakeClickHouse;

    sub new {
        my ($class) = @_;
        return bless {
            requests => [],   # every request, in order
            visible  => [],   # rows a SELECT can see
            pending  => [],   # rows parked in the async buffer
        }, $class;
    }

    sub selects { return grep { $_->{sql} =~ /^\s*SELECT/i } @{ $_[0]{requests} } }
    sub writes  { return grep { $_->{sql} =~ /INSERT|ALTER/i } @{ $_[0]{requests} } }

    sub flush_async { my ($s) = @_; push @{ $s->{visible} }, @{ $s->{pending} }; $s->{pending} = []; return }

    sub request { my ($s, undef, $url, $opts) = @_; return $s->post($url, $opts) }

    sub post {
        my ($self, $url, $opts) = @_;
        my $sql = $opts->{content} // '';
        push @{ $self->{requests} }, { url => $url, sql => $sql };

        my $sync = $url =~ /async_insert=0/ ? 1 : 0;

        if ($sql =~ /INSERT\s+INTO\s+\S*\.alerts\b.*?VALUES\s*\((.*)\)/is) {
            my $values = $1;
            my ($name) = $values =~ /'([^']*)'/;
            my $row = { id => 'id-' . scalar(@{ $self->{visible} }) . scalar(@{ $self->{pending} }),
                        name => $name // '' };
            push @{ $sync ? $self->{visible} : $self->{pending} }, $row;
        }
        elsif ($sql =~ /ALTER\s+TABLE\s+\S*\.alerts\s+DELETE\s+WHERE\s+id\s*=\s*'([^']*)'/is) {
            my $id = $1;
            # mutations_sync=0 means the delete is applied in the background;
            # model that as "not applied yet".
            if ($url =~ /mutations_sync=1/) {
                $self->{visible} = [ grep { $_->{id} ne $id } @{ $self->{visible} } ];
            }
        }

        my $content = '';
        if ($sql =~ /^\s*SELECT.*FROM\s+\S*\.alerts/is) {
            $content = join('', map { qq({"id":"$_->{id}","name":"$_->{name}"}\n) }
                                 @{ $self->{visible} });
        }
        elsif ($sql =~ /^\s*SELECT\s+count\(\)/is) {
            $content = qq({"cnt":"0"}\n);
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

# ============================================
# Write path
# ============================================

subtest 'CRUD insert is synchronous, ingest insert is not' => sub {
    my $s = new_storage();
    my $ch = $s->_http;
    @{ $ch->{requests} } = ();

    $s->create_alert(name => 'disk full', query => 'level:error');

    my ($insert) = grep { $_->{sql} =~ /INSERT INTO/ } @{ $ch->{requests} };
    ok $insert, 'an INSERT was issued';
    like $insert->{url}, qr/async_insert=0/, 'CRUD insert disables the async buffer';
    unlike $insert->{url}, qr/wait_for_async_insert/,
        'CRUD insert does not ride the ingest async settings at all';

    # The ingest path must KEEP its throughput-oriented settings. flush() puts
    # the INSERT in the URL and streams JSONEachRow as the body.
    @{ $ch->{requests} } = ();
    $s->insert({ level => 'INFO', service => 'x', message => 'y' });
    $s->flush;
    my ($ingest) = grep { $_->{url} =~ /INSERT\+INTO|INSERT%20INTO/ } @{ $ch->{requests} };
    ok $ingest, 'ingest INSERT was issued';
    like $ingest->{url}, qr/async_insert=1/, 'ingest still uses async insert';
    unlike $ingest->{url}, qr/mutations_sync/, 'ingest not slowed by mutation syncing';
};

subtest 'CRUD update and delete wait for the mutation' => sub {
    my $s = new_storage();
    my $ch = $s->_http;
    my $uuid = '11111111-2222-3333-4444-555555555555';

    @{ $ch->{requests} } = ();
    $s->update_alert($uuid, name => 'renamed');
    my ($upd) = grep { $_->{sql} =~ /ALTER TABLE/ } @{ $ch->{requests} };
    ok $upd, 'an ALTER ... UPDATE was issued';
    like $upd->{url}, qr/mutations_sync=1/, 'update waits for the mutation to apply';

    @{ $ch->{requests} } = ();
    $s->delete_alert($uuid);
    my ($del) = grep { $_->{sql} =~ /ALTER TABLE/ } @{ $ch->{requests} };
    ok $del, 'an ALTER ... DELETE was issued';
    like $del->{url}, qr/mutations_sync=1/, 'delete waits for the mutation to apply';
};

# ============================================
# Read path
# ============================================

subtest 'CRUD list is never served from the query cache' => sub {
    my $s = new_storage();
    my $ch = $s->_http;

    $s->create_alert(name => 'a1');
    @{ $ch->{requests} } = ();

    $s->get_alerts for 1 .. 3;
    my @selects = grep { $_->{sql} =~ /FROM purl\.alerts/ } @{ $ch->{requests} };
    is scalar(@selects), 3,
        'three list calls hit ClickHouse three times (a cached second call is a stale read)';
};

subtest 'alert list caching does not disable log query caching' => sub {
    my $s = new_storage();
    my $ch = $s->_http;
    ok $s->use_query_cache, 'query cache still enabled globally';
    @{ $ch->{requests} } = ();
    $s->count(service => 'api');
    $s->count(service => 'api');
    my @c = grep { $_->{sql} =~ /count\(\)/ } @{ $ch->{requests} };
    is scalar(@c), 1, 'identical log counts are still cached (throughput path untouched)';
};

# ============================================
# End to end: create then immediately list, repeatedly.
# ============================================

subtest 'a created alert is visible to the very next list, every time' => sub {
    my $s = new_storage();

    for my $i (1 .. 20) {
        $s->create_alert(name => "alert-$i");
        my $listed = $s->get_alerts;
        is scalar(@$listed), $i, "iteration $i: list contains all $i alerts";
    }

    # Nothing is stuck in the async buffer waiting to appear later.
    is scalar(@{ $s->_http->{pending} }), 0, 'no CRUD row left in the async buffer';
};

subtest 'a deleted alert disappears from the very next list' => sub {
    my $s = new_storage();
    $s->create_alert(name => 'doomed');
    my $listed = $s->get_alerts;
    is scalar(@$listed), 1, 'alert created';

    $s->delete_alert('11111111-2222-3333-4444-555555555555');
    # id from the fake store, not a real uuid — delete by the real id:
    my $id = $listed->[0]{id};
    $s->_http->post('http://fake/?mutations_sync=1',
        { content => "ALTER TABLE purl.alerts DELETE WHERE id = '$id'" });

    is scalar(@{ $s->get_alerts }), 0, 'delete is visible immediately';
};

done_testing();

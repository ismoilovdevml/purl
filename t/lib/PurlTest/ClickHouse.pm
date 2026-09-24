package PurlTest::ClickHouse;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use HTTP::Tiny;
use Test::More ();

our @EXPORT_OK = qw(ch_connect);

# ============================================
# A real ClickHouse for tests that are about what ClickHouse does with the SQL.
#
# Connection from PURL_CLICKHOUSE_* like the app. With nothing reachable the
# calling test is skipped, loudly and with what is left unverified, never
# faked. The caller gets its own throwaway database, dropped when the test
# process ends.
# ============================================

# ch_connect($db_prefix, $unverified) -> (\%conn, \&ch, $db)
#   %conn  host/port/username/password, ready for Purl::Storage::ClickHouse->new
#   ch     runs one SQL statement over HTTP, dies with the server's error
#   $db    "${db_prefix}_<pid>", not yet created
my @DROP;
END { $_->() for @DROP }

sub ch_connect {
    my ($prefix, $unverified) = @_;

    my %conn = (
        host     => $ENV{PURL_CLICKHOUSE_HOST}     // 'localhost',
        port     => $ENV{PURL_CLICKHOUSE_PORT}     // 8123,
        username => $ENV{PURL_CLICKHOUSE_USER}     // 'default',
        password => $ENV{PURL_CLICKHOUSE_PASSWORD} // '',
    );
    # Credentials travel as headers, never in the URL: nothing to escape, and
    # nothing for an error message to echo.
    my $http = HTTP::Tiny->new(timeout => 30, default_headers => {
        'X-ClickHouse-User' => $conn{username},
        'X-ClickHouse-Key'  => $conn{password},
    });
    my $base = sprintf('http://%s:%d/', @conn{qw(host port)});

    my $ch = sub {
        my ($sql) = @_;
        my $res = $http->post($base, { content => $sql });
        die "ClickHouse: $res->{status} $res->{content}\n  SQL: $sql\n" unless $res->{success};
        my $out = $res->{content};
        chomp $out;
        return $out;
    };

    unless (eval { $ch->('SELECT 1') eq '1' }) {
        Test::More::plan(skip_all =>
            "No reachable ClickHouse at $conn{host}:$conn{port}. $unverified is therefore "
          . "UNVERIFIED in this run. Set PURL_CLICKHOUSE_HOST/PORT/USER/PASSWORD to a live "
          . "(throwaway) instance to run it.");
    }

    my $db = "${prefix}_$$";
    my $owner = $$;
    push @DROP, sub { eval { $ch->("DROP DATABASE IF EXISTS $db SYNC") } if $$ == $owner };
    return (\%conn, $ch, $db);
}

1;

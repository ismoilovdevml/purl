#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path remove_tree);
use IO::Socket::INET;
use HTTP::Tiny;
use Encode qw(decode FB_CROAK);
use JSON::PP ();
use POSIX ();

# ============================================
# REGRESSION (#107): when ClickHouse failed (memory limit on purl.edcom.uz),
# the Logs page, Patterns panel and toasts showed the raw ClickHouse exception
# (part paths, table UUIDs, SQL), Perl die text with file/line
#   "... service unavailable at /app/lib/Purl/Storage/ClickHouse/CircuitBreaker.pm line 45."
# and mojibake ("open a-circumflex euro service": an em dash encoded twice).
#
# The app below runs on the REAL Purl::Storage::ClickHouse transport, talking
# to a fake ClickHouse HTTP server (a forked child) that answers with bodies
# captured from clickhouse-server:25.11 (the version docker-compose ships).
# Connection refused and read timeout are real socket conditions; circuit-open
# is the real breaker. Every failure, through search, histogram, patterns and
# alerts, must come back as {error, code, request_id} with the right status,
# no internals, valid UTF-8 JSON, and the full detail logged under that id.
# ============================================

my $DIR;
BEGIN {
    $DIR = "/tmp/purl_api_error_contract_$$";
    $ENV{PURL_AUTH_ENABLED}         = '0';
    $ENV{PURL_ADMIN_PASSWORD}       = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}         = '0';
    $ENV{PURL_SAML_ENABLED}         = '0';
    $ENV{PURL_SESSION_SECRET}       = 'api-error-contract-secret-0123456789abcdef';
    $ENV{PURL_CONFIG_FILE}          = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}           = $DIR;
    $ENV{PURL_ALERT_CHECK_INTERVAL} = '0';
    $ENV{PURL_BROADCAST_MODE}       = 'local';
}
make_path($DIR);

# --------------------------------------------
# Fake ClickHouse: answers every request according to $MODE_FILE, re-read per
# request so the test can switch behaviour between cases.
#   ok                 200, empty body
#   sleep              never answers within the client timeout
#   <status>\n<body>   that status and body
# --------------------------------------------
my $MODE_FILE = "$DIR/ch_mode";
sub set_mode {
    my ($mode) = @_;
    open my $fh, '>:raw', "$MODE_FILE.tmp" or die "mode: $!";
    print {$fh} $mode;
    close $fh;
    rename "$MODE_FILE.tmp", $MODE_FILE or die "rename: $!";
    return;
}
set_mode('ok');

my $listener = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 32, ReuseAddr => 1, Proto => 'tcp',
) or die "listen: $!";
my $CH_PORT = $listener->sockport;

my $server_pid = fork() // die "fork: $!";
if (!$server_pid) {
    $SIG{CHLD} = 'IGNORE';
    while (my $conn = $listener->accept) {
        my $pid = fork();
        if (defined $pid && $pid == 0) {
            _serve($conn);
            POSIX::_exit(0);
        }
        close $conn;
    }
    POSIX::_exit(0);
}
close $listener;

sub _serve {
    my ($conn) = @_;
    local $/ = "\r\n";
    my $len = 0;
    while (my $line = <$conn>) {
        last if $line eq "\r\n";
        $len = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
    }
    read($conn, my $discard, $len) if $len;

    open my $fh, '<:raw', $MODE_FILE or return;
    my $mode = do { local $/; <$fh> };
    close $fh;

    if ($mode eq 'sleep') { sleep 5; return }

    my ($status, $body) = $mode eq 'ok' ? (200, '') : split /\n/, $mode, 2;
    my $reason = $status == 200 ? 'OK' : 'Error';
    print {$conn} "HTTP/1.1 $status $reason\r\n"
        . "Content-Type: text/plain; charset=UTF-8\r\n"
        . 'Content-Length: ' . length($body) . "\r\n"
        . "Connection: close\r\n\r\n"
        . $body;
    return;
}

END {
    local $?;   # the reaped server's KILL status must not become ours
    if ($server_pid) { kill 'KILL', $server_pid; waitpid $server_pid, 0 }
    remove_tree($DIR) if $DIR;
}

# A port nothing listens on: bind, read the number, close.
my $CLOSED_PORT = do {
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1)
        or die "probe: $!";
    my $p = $s->sockport;
    close $s;
    $p;
};

$ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
$ENV{PURL_CLICKHOUSE_PORT} = $CH_PORT;

# Build the real ClickHouse storage, and keep a handle on the one object the
# controllers share so each case can re-point it or set its breaker.
require Purl::API::Server;
require Purl::API::Server::Builders;
my $storage;
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub {
        return $storage = Purl::API::Server::Builders::build_storage({});
    };
}
my $app = Purl::API::Server->create(config => { auth => { enabled => 0 } })->setup_routes;

# Capture the app log (and keep the test output quiet).
my @LOG;
$app->log->unsubscribe('message');
$app->log->level('debug');
$app->log->on(message => sub {
    my ($log, $level, @lines) = @_;
    push @LOG, "[$level] " . join(' ', @lines);
});

use Test::Mojo;
my $t = Test::Mojo->new($app);

# ClickHouse 25.11 error bodies (captured from a real server; the part path and
# UUID ones are the shapes seen in production).
my %CH = (
    memory => [500, "Code: 241. DB::Exception: Query memory limit exceeded: would use 1.65 MiB "
        . "(attempt to allocate chunk of 0.00 B), maximum: 976.56 KiB: While executing "
        . "AggregatingTransform. (MEMORY_LIMIT_EXCEEDED) (version 25.11.9.34 (official build))\n"],
    too_many_parts => [500, "Code: 252. DB::Exception: Too many parts (3001 with average size of "
        . "12.34 KiB) in table 'purl.logs (2f6b1c3e-8d4a-4f5e-9b7a-1c2d3e4f5a6b)'. Merges are "
        . "processing significantly slower than inserts. (TOO_MANY_PARTS) (version 25.11.9.34 (official build))\n"],
    timeout => [408, "Code: 159. DB::Exception: Timeout exceeded: elapsed 1000.204459 ms, maximum: "
        . "1000 ms. (TIMEOUT_EXCEEDED) (version 25.11.9.34 (official build))\n"],
    regexp => [400, "Code: 427. DB::Exception: OptimizedRegularExpression: cannot compile re2: (, "
        . "error: missing ): (. In scope SELECT timestamp, level, service, message FROM purl.logs "
        . "WHERE match(message, '('). (CANNOT_COMPILE_REGEXP) (version 25.11.9.34 (official build))\n"],
    corrupted => [500, "Code: 33. DB::Exception: Cannot read all data. Bytes read: 12. Bytes expected: 40.: "
        . "(while reading column message): (while reading from part "
        . "/var/lib/clickhouse/store/2f6/2f6b1c3e-8d4a-4f5e-9b7a-1c2d3e4f5a6b/202609_1_1_0/ in table "
        . "purl.logs (2f6b1c3e-8d4a-4f5e-9b7a-1c2d3e4f5a6b) located on disk default of type local, "
        . "from mark 0 with max_rows_to_read = 8192): While executing MergeTreeSelect(pool: ReadPool, "
        . "algorithm: Thread). (CANNOT_READ_ALL_DATA) (version 25.11.9.34 (official build))\n"],
);

my @ROUTES = (
    [ search    => '/api/logs?q=boom&range=1h' ],
    [ histogram => '/api/stats/histogram?range=1h' ],
    [ patterns  => '/api/patterns?range=1h' ],
    [ alerts    => '/api/alerts' ],
);

sub reset_breaker {
    $storage->_circuit_state('closed');
    $storage->_consecutive_failures(0);
    $storage->{port} = $CH_PORT;
    $storage->{_http} = HTTP::Tiny->new(timeout => 1, keep_alive => 0, max_redirect => 0);
    return;
}

# Everything a response body must never contain.
my @LEAKS = (
    [ qr{/app/|/var/lib|/usr/|\.pm\b}      => 'a file path' ],
    [ qr{ at \S+ line \d+|\bline \d+\b}    => 'a Perl file/line' ],
    [ qr{[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}i => 'a UUID' ],
    [ qr{\d{6}_\d+_\d+_\d+}                => 'a part name' ],
    [ qr{\bSELECT\b|\bFROM\b|\bWHERE\b|purl\.logs|DB::Exception|Code: \d+} => 'SQL / ClickHouse text' ],
    [ qr{[\x{80}-\x{ff}]}               => 'double-encoded (mojibake) text' ],
);

sub check_error_response {
    my (%x) = @_;
    my $name = $x{name};
    my $tx   = $t->tx;
    my $res  = $tx->res;

    is $res->code, $x{status}, "$name: status $x{status}";

    my $raw  = $res->body;
    my $text = eval { decode('UTF-8', $raw, FB_CROAK) };
    ok defined $text, "$name: body is valid UTF-8";
    my $json = eval { JSON::PP->new->decode($text // '') };
    is ref $json, 'HASH', "$name: body is a JSON object" or diag $raw;
    $json //= {};

    is $json->{code}, $x{code}, "$name: code $x{code}";
    ok length($json->{error} // ''), "$name: has a user-facing error";
    like $json->{request_id} // '', qr/\A\S{4,}\z/, "$name: has a request_id";
    is $res->headers->header('X-Request-Id'), $json->{request_id}, "$name: X-Request-Id header matches";

    for my $leak (@LEAKS) {
        unlike $text // '', $leak->[0], "$name: body carries no $leak->[1]";
    }

    if ($x{retry_after}) {
        ok $res->headers->header('Retry-After'), "$name: Retry-After header";
    }

    if ($x{log_like}) {
        my $rid = $json->{request_id} // 'none';
        my @hit = grep { index($_, "request_id=$rid") >= 0 } @LOG;
        ok scalar(@hit), "$name: server log has a line with request_id=$rid";
        like join("\n", @hit), $x{log_like}, "$name: ... carrying the full detail";
    }
    return $json;
}

# Startup ran schema init against the fake server in 'ok' mode.
ok $storage, 'got the shared storage object' or BAIL_OUT('no storage handle');

for my $route (@ROUTES) {
    my ($what, $url) = @$route;

    subtest "$what: ClickHouse memory limit -> 503 storage_overloaded" => sub {
        reset_breaker();
        set_mode(join "\n", @{ $CH{memory} });
        $t->get_ok($url);
        check_error_response(name => $what, status => 503, code => 'storage_overloaded',
            retry_after => 1, log_like => qr/MEMORY_LIMIT_EXCEEDED/);
    };

    subtest "$what: too many parts (table UUID in text) -> 503 storage_overloaded" => sub {
        reset_breaker();
        set_mode(join "\n", @{ $CH{too_many_parts} });
        $t->get_ok($url);
        check_error_response(name => $what, status => 503, code => 'storage_overloaded',
            retry_after => 1, log_like => qr/TOO_MANY_PARTS/);
    };

    subtest "$what: ClickHouse TIMEOUT_EXCEEDED -> 504 query_timeout" => sub {
        reset_breaker();
        set_mode(join "\n", @{ $CH{timeout} });
        $t->get_ok($url);
        check_error_response(name => $what, status => 504, code => 'query_timeout',
            log_like => qr/TIMEOUT_EXCEEDED/);
    };

    subtest "$what: read timeout (no answer) -> 504 query_timeout" => sub {
        reset_breaker();
        set_mode('sleep');
        $t->get_ok($url);
        check_error_response(name => $what, status => 504, code => 'query_timeout',
            log_like => qr/599/);
    };

    subtest "$what: connection refused -> 503 storage_unavailable" => sub {
        reset_breaker();
        $storage->{port} = $CLOSED_PORT;
        $t->get_ok($url);
        check_error_response(name => $what, status => 503, code => 'storage_unavailable',
            retry_after => 1, log_like => qr/599/);
    };

    subtest "$what: circuit breaker open -> 503 storage_unavailable, no file/line" => sub {
        reset_breaker();
        $storage->_circuit_state('open');
        $storage->_circuit_opened_at(time());
        $t->get_ok($url);
        check_error_response(name => $what, status => 503, code => 'storage_unavailable',
            retry_after => 1, log_like => qr/circuit breaker is open/);
        # The exact production leak: the die text used to carry file and line.
        unlike join("\n", @LOG), qr/CircuitBreaker\.pm line/, 'breaker die has no file/line even in the log';
    };

    subtest "$what: corrupted part (disk path + UUID) -> 500 internal" => sub {
        reset_breaker();
        set_mode(join "\n", @{ $CH{corrupted} });
        $t->get_ok($url);
        check_error_response(name => $what, status => 500, code => 'internal',
            log_like => qr{/var/lib/clickhouse/store/});
    };
}

subtest 'search: a user regex ClickHouse rejects -> 400 invalid_query, helpful but sanitized' => sub {
    reset_breaker();
    set_mode(join "\n", @{ $CH{regexp} });
    $t->get_ok('/api/logs?q=boom&range=1h');
    my $json = check_error_response(name => 'regexp', status => 400, code => 'invalid_query',
        log_like => qr/CANNOT_COMPILE_REGEXP/);
    like $json->{error}, qr/regular expression/i, 'says what is wrong';
};

subtest 'unauthenticated /api/health does not echo the ClickHouse exception' => sub {
    for my $url ('/api/health', '/api/health/ready') {
        reset_breaker();
        set_mode(join "\n", @{ $CH{corrupted} });
        $t->get_ok($url)->status_is(503);
        my $body = $t->tx->res->body;
        for my $leak (@LEAKS) {
            unlike $body, $leak->[0], "$url: no $leak->[1]";
        }
        $t->json_is('/error' => 'Internal server error');
    }
};

subtest 'an exception escaping a handler under /api is shaped too' => sub {
    my $r = $app->routes->get('/api/__test_die' => sub {
        die "kaboom in SELECT * FROM purl.logs at /app/lib/Purl/Fake.pm line 7.\n";
    });
    # Mojolicious matches in definition order; move it ahead of the /api 404.
    my $children = $app->routes->children;
    unshift @$children, pop @$children;

    $t->get_ok('/api/__test_die');
    check_error_response(name => 'uncaught', status => 500, code => 'internal',
        log_like => qr/kaboom/);
};

subtest 'explicit render_error bodies carry code + request_id' => sub {
    $t->get_ok('/api/does/not/exist')->status_is(404)
      ->json_is('/code' => 'not_found')
      ->json_is('/error' => 'Not found')
      ->json_like('/request_id' => qr/\S/);
};

reset_breaker();
set_mode('ok');

done_testing;

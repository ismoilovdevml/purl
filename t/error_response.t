#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::ErrorResponse qw(
    classify_error strip_location exception_response message_response
);
use Purl::API::Controller::Base;

# ============================================
# Unit contract of the single API error-shaping path (#107): classification of
# storage failures into stable codes, the {error, code, request_id} body, and
# that exception text never reaches it. The end-to-end version (real transport,
# real routes) is t/api_error_contract.t.
# ============================================

{
    package ErrCtx;
    sub new     { return bless { logs => [], rendered => undef }, $_[0] }
    sub app     { return $_[0] }
    sub log     { return $_[0] }
    sub error   { my ($s, $m) = @_; push @{ $s->{logs} }, "error $m"; return }
    sub warn    { my ($s, $m) = @_; push @{ $s->{logs} }, "warn $m";  return }
    sub render  { my ($s, %a) = @_; $s->{rendered} = \%a; return }
    sub logs    { return $_[0]->{logs} }
}

my $CH = 'ClickHouse error: 500 - ';
my @CASES = (
    # [ die text, expected code, message like ]
    [ $CH . "Code: 241. DB::Exception: Memory limit (total) exceeded: would use 15.02 GiB. OvercommitTracker decision. (MEMORY_LIMIT_EXCEEDED) (version 25.11.9.34 (official build))\n",
      'storage_overloaded', qr/overloaded/ ],
    [ $CH . "Code: 252. DB::Exception: Too many parts (3001). (TOO_MANY_PARTS) (version 25.11.9.34 (official build))\n",
      'storage_overloaded', qr/overloaded/ ],
    [ $CH . "Code: 202. DB::Exception: Too many simultaneous queries. Maximum: 100.\n",
      'storage_overloaded', qr/overloaded/ ],   # numeric code, no name
    [ 'ClickHouse error: 408 - ' . "Code: 159. DB::Exception: Timeout exceeded: elapsed 1000.2 ms, maximum: 1000 ms. (TIMEOUT_EXCEEDED) (version 25.11.9.34 (official build))\n",
      'query_timeout', qr/too long/ ],
    [ "ClickHouse error: 599 - Timed out while waiting for socket to become ready for reading\n",
      'query_timeout', qr/too long/ ],
    [ "ClickHouse error: 599 - Could not connect to '127.0.0.1:8123': Connection refused\n",
      'storage_unavailable', qr/unavailable/ ],
    [ "ClickHouse insert error: 599 - Could not connect to 'ch:8123': Connection refused\n",
      'storage_unavailable', qr/unavailable/ ],
    [ "ClickHouse circuit breaker is open - service unavailable\n",
      'storage_unavailable', qr/unavailable/ ],
    [ $CH . "Code: 81. DB::Exception: Database purl does not exist. (UNKNOWN_DATABASE) (version 25.11.9.34 (official build))\n",
      'storage_unavailable', qr/unavailable/ ],
    [ 'ClickHouse error: 400 - ' . "Code: 62. DB::Exception: Syntax error: failed at position 1 (SELEC): SELEC 1. Expected one of: Query. (SYNTAX_ERROR) (version 25.11.9.34 (official build))\n",
      'invalid_query', qr/\AQuery syntax error\z/ ],
    [ 'ClickHouse error: 400 - ' . "Code: 427. DB::Exception: OptimizedRegularExpression: cannot compile re2: (, error: missing ): (. In scope SELECT match('a', '('). (CANNOT_COMPILE_REGEXP) (version 25.11.9.34 (official build))\n",
      'invalid_query', qr/regular expression/ ],
    [ 'ClickHouse error: 404 - ' . "Code: 47. DB::Exception: Unknown expression identifier `nosuchcol` in scope SELECT nosuchcol FROM purl.logs. (UNKNOWN_IDENTIFIER) (version 25.11.9.34 (official build))\n",
      'invalid_query', qr/Unknown field/ ],
    [ $CH . "Code: 158. DB::Exception: Limit for rows (controlled by 'max_rows_to_read' setting) exceeded, max rows: 10.00. (TOO_MANY_ROWS) (version 25.11.9.34 (official build))\n",
      'invalid_query', qr/too much data/ ],
    [ $CH . "Code: 33. DB::Exception: Cannot read all data (while reading from part /var/lib/clickhouse/store/2f6/2f6b1c3e-8d4a-4f5e-9b7a-1c2d3e4f5a6b/202609_1_1_0/). (CANNOT_READ_ALL_DATA)\n",
      'internal', qr/\AInternal server error\z/ ],
    [ "Backup not found\n",                                         'not_found', qr/\ANot found\z/ ],
    [ "Backup not found at /app/lib/Purl/Storage/ClickHouse/Backup.pm line 234.\n", 'not_found', qr/\ANot found\z/ ],
    [ "Backup directory not found: /app/backups/x\n",               'internal',  qr/Internal/ ],
    [ "Can't call method \"x\" on an undefined value at /app/lib/Purl/X.pm line 9.\n", 'internal', qr/Internal/ ],
    [ undef,                                                         'internal',  qr/Internal/ ],
);

subtest 'classify_error: storage failures map to stable codes' => sub {
    for my $case (@CASES) {
        my ($err, $want_code, $want_msg) = @$case;
        my ($code, $message) = classify_error($err);
        my $label = substr($err // 'undef', 0, 60);
        is $code, $want_code, "code for: $label";
        like $message, $want_msg, "message for: $label";
        unlike $message, qr{/|DB::Exception|SELECT|\bline \d}, "message leaks nothing: $label";
        unlike $message, qr/[^\x00-\x7F]/, "message is ASCII: $label";
    }
};

subtest 'exception_response: status, headers-free fallback, full detail logged' => sub {
    my %want = (storage_unavailable => 503, storage_overloaded => 503, query_timeout => 504,
                invalid_query => 400, not_found => 404, internal => 500);
    for my $case (@CASES) {
        my ($err, $want_code) = @$case;
        my $c = ErrCtx->new;
        my ($status, $body) = exception_response($c, $err, context => 'unit');
        is $status, $want{$want_code}, "status for $want_code";
        is_deeply [ sort keys %$body ],
            [ sort('error', 'code', 'request_id', ($status == 503 ? 'retry_after' : ())) ],
            'body keys are exactly the contract';
        like $body->{request_id}, qr/\A[0-9a-f]{16}\z/, 'a stand-in without a Mojo request gets a random id';
        my ($line) = @{ $c->logs };
        like $line, qr/\Q[request_id=$body->{request_id}]\E/, 'log line carries the same id';
        my $head = substr($err // 'unknown error', 0, 20);
        ok index($line, "unit: $head") >= 0, 'log line carries the full error';
    }
};

subtest 'strip_location removes Perl file/line, keeps the message' => sub {
    is strip_location("Connection refused at /app/lib/Purl/X.pm line 45.\n"), 'Connection refused';
    is strip_location("bad at lib/X.pm line 3, <\$fh> line 12.\n"), 'bad';
    is strip_location("plain message\n"), 'plain message';
    is strip_location(undef), '';
};

subtest 'message_response: code from status, 5xx logged, 4xx not' => sub {
    my %codes = (400 => 'bad_request', 401 => 'unauthorized', 403 => 'forbidden',
                 404 => 'not_found', 409 => 'conflict', 429 => 'rate_limited', 500 => 'internal');
    for my $status (sort keys %codes) {
        my $c = ErrCtx->new;
        my ($got, $body) = message_response($c, 'Something', $status);
        is $got, $status, "status $status kept";
        is $body->{code}, $codes{$status}, "code $codes{$status}";
        is $body->{error}, 'Something', 'caller message kept';
        is scalar @{ $c->logs }, ($status >= 500 ? 1 : 0), 'logged only when 5xx';
    }
    my ($s, $b) = message_response(ErrCtx->new, 'Bad query', 400, 'invalid_query');
    is $b->{code}, 'invalid_query', 'explicit code wins';
};

subtest 'Base: safe_execute renders the classified error, not the die text' => sub {
    my $ctrl = Purl::API::Controller::Base->new(storage => bless({}, 'NoStorage'));
    my $c = ErrCtx->new;
    $ctrl->safe_execute($c, sub {
        die "ClickHouse circuit breaker is open - service unavailable\n";
    });
    my $r = $c->{rendered};
    is $r->{status}, 503, 'status is 503';
    is $r->{json}{code}, 'storage_unavailable', 'code';
    unlike $r->{json}{error}, qr/circuit|\.pm/, 'no internals in the message';

    $c = ErrCtx->new;
    $ctrl->safe_execute($c, sub { die "boom at /app/lib/Purl/Y.pm line 1.\n" });
    is $c->{rendered}{status}, 500, 'unknown error -> 500';
    is $c->{rendered}{json}{error}, 'Internal server error', 'generic message';
    like $c->logs->[0], qr/boom at \/app\/lib\/Purl\/Y\.pm line 1/, 'full text only in the log';
};

done_testing;

package Purl::Util::ErrorResponse;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);
use Purl::Storage::ClickHouse::Errors qw(classify_clickhouse_error);
use Purl::Util::Random qw(random_hex);

our @EXPORT_OK = qw(
    exception_response
    message_response
    classify_error
    strip_location
    request_id
);

# ============================================
# The ONE place an API error body is shaped (#107).
#
# Every error the API returns has the contract
#
#     { "error": "<short user-facing sentence>",
#       "code":  "<stable machine code>",
#       "request_id": "<id>" }
#
# plus an X-Request-Id header, and Retry-After on 503. The full original error
# goes to the server log on a line carrying the same request id, so a user can
# quote the id and an operator can find the detail.
#
# Exception text is NEVER copied into the body: before this, users saw
# ClickHouse part paths, table UUIDs, SQL and "... at /app/lib/... line 45."
# An exception is classified into a code and the body gets the fixed message
# for that code. The only per-error wording is invalid_query's, and that too is
# a fixed sentence per ClickHouse exception type, never echoed text.
#
# Messages are ASCII on purpose: a non-ASCII literal in a source file without
# `use utf8` is a byte string, and JSON-encoding it double-encodes it (the
# "open a-circumflex euro service" mojibake).
# ============================================

my %CLASS = (
    storage_unavailable => { status => 503, retry_after => 30,
        message => 'Log storage is temporarily unavailable. Please retry shortly.' },
    storage_overloaded  => { status => 503, retry_after => 15,
        message => 'Log storage is overloaded. Please retry shortly or narrow the time range.' },
    query_timeout       => { status => 504,
        message => 'The query took too long. Narrow the time range or add filters.' },
    invalid_query       => { status => 400, message => 'Invalid query' },
    not_found           => { status => 404, message => 'Not found' },
    forbidden           => { status => 403, message => 'Forbidden' },
    internal            => { status => 500, message => 'Internal server error' },
);

# Code for an explicitly rendered status when the caller names none.
my %CODE_BY_STATUS = (
    400 => 'bad_request',
    401 => 'unauthorized',
    403 => 'forbidden',
    404 => 'not_found',
    409 => 'conflict',
    413 => 'payload_too_large',
    429 => 'rate_limited',
    503 => 'storage_unavailable',
    504 => 'query_timeout',
);

# Remove the " at FILE line N." Perl appends to a die/warn without a trailing
# newline (and the ", <$fh> line N." variant), then trim. For diagnostics that
# are deliberately shown to an admin (connection tests): the message stays,
# the source location does not.
sub strip_location {
    my ($text) = @_;
    $text = "$text" if defined $text;
    return '' unless defined $text;
    $text =~ s/\s+at \S+ line \d+(?:, <[^>]*> (?:line|chunk) \d+)?\.?//g;
    $text =~ s/\A\s+|\s+\z//g;
    return $text;
}

# classify_error($err) -> ($code, $message)
#
# $message is the user-facing sentence for $code.
sub classify_error {
    my ($err) = @_;
    my $text = defined $err ? "$err" : q{};

    if (my ($code, $message) = classify_clickhouse_error($text)) {
        return ($code, $message // $CLASS{$code}{message});
    }

    # A control-flow "<Thing> not found" die from the storage layer.
    return ('not_found', $CLASS{not_found}{message})
        if strip_location($text) =~ /\A[\w ]{1,60} not found\.?\z/i;

    return ('internal', $CLASS{internal}{message});
}

# Mojo gives every request an id; reuse it so it matches Mojo's own log
# context. A controller stand-in without one (unit tests) gets a random id.
sub request_id {
    my ($c) = @_;
    my $id = eval { $c->req->request_id };
    return $id if defined $id && length $id;
    return random_hex(8);
}

# exception_response($c, $err, %opt) -> ($status, \%body)
#
# For a caught exception. Logs the full error with the request id, sets the
# response headers, and returns what to render. %opt:
#   context => 'what was being done'   prefixed to the log line only
sub exception_response {
    my ($c, $err, %opt) = @_;

    my ($code, $message) = classify_error($err);
    my $detail = defined $err ? "$err" : 'unknown error';
    $detail = "$opt{context}: $detail" if $opt{context};

    return _respond($c,
        status      => $CLASS{$code}{status},
        code        => $code,
        message     => $message,
        retry_after => $CLASS{$code}{retry_after},
        log_detail  => $detail,
    );
}

# message_response($c, $message, $status, $code) -> ($status, \%body)
#
# For an error the caller phrased itself ("Invalid log ID format"). The message
# is the caller's literal, not exception text. A 5xx is logged.
sub message_response {
    my ($c, $message, $status, $code) = @_;
    $status //= 500;
    $code   //= $CODE_BY_STATUS{$status} // ($status >= 500 ? 'internal' : 'bad_request');

    return _respond($c,
        status      => $status,
        code        => $code,
        message     => $message,
        retry_after => ($CLASS{$code} // {})->{retry_after},
        ($status >= 500 ? (log_detail => $message) : ()),
    );
}

sub _respond {
    my ($c, %r) = @_;

    my $rid = request_id($c);

    # A logging or header failure must not turn an error response into a
    # second, unhandled error — the caller still has to render something.
    eval {
        my $headers = $c->res->headers;
        $headers->header('X-Request-Id' => $rid);
        $headers->header('Retry-After' => $r{retry_after}) if $r{retry_after};
        1;
    };

    if (defined $r{log_detail}) {
        my $level = $r{status} >= 500 ? 'error' : 'warn';
        eval {
            $c->app->log->$level("[request_id=$rid] $r{status} $r{code}: $r{log_detail}");
            1;
        };
    }

    my %body = (
        error      => $r{message},
        code       => $r{code},
        request_id => $rid,
    );
    $body{retry_after} = $r{retry_after} + 0 if $r{retry_after};

    return ($r{status}, \%body);
}

1;

__END__

=head1 NAME

Purl::Util::ErrorResponse - the single shaping path for API error bodies:
{error, code, request_id}, Retry-After on 503, full detail only in the server log

=cut

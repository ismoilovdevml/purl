package Purl::Storage::ClickHouse::Errors;
use strict;
use warnings;
use 5.024;

use Exporter qw(import);

our @EXPORT_OK = qw(classify_clickhouse_error);

# ============================================
# What a ClickHouse failure MEANS for the caller, read off the text the storage
# layer dies with (#107).
#
# Connection.pm dies with "ClickHouse error: <http status> - <server body>",
# where the body is ClickHouse's own exception text:
#
#   Code: 241. DB::Exception: Query memory limit exceeded: ... (MEMORY_LIMIT_EXCEEDED) (version 25.11...)
#
# That text carries SQL fragments, table UUIDs and on-disk part paths, so it is
# never shown to a user. This module only decides WHICH stable class it is; the
# API layer (Purl::Util::ErrorResponse) owns the user-facing wording.
#
# Matched by the exception NAME ClickHouse prints in parentheses, falling back
# to the numeric code for servers that do not print names. Status 599 is
# HTTP::Tiny's own "no HTTP response" (connect refused, reset, read timeout).
# ============================================

my %CLASS_BY_NAME = (
    # The server is up but has no room for this query right now.
    MEMORY_LIMIT_EXCEEDED          => 'storage_overloaded',
    CANNOT_ALLOCATE_MEMORY         => 'storage_overloaded',
    TOO_MANY_PARTS                 => 'storage_overloaded',
    TOO_MANY_SIMULTANEOUS_QUERIES  => 'storage_overloaded',

    # The query ran out of its time budget.
    TIMEOUT_EXCEEDED               => 'query_timeout',
    SOCKET_TIMEOUT                 => 'query_timeout',
    QUERY_WAS_CANCELLED            => 'query_timeout',

    # The server (or the database we need) cannot be used at all.
    NETWORK_ERROR                  => 'storage_unavailable',
    ALL_CONNECTION_TRIES_FAILED    => 'storage_unavailable',
    AUTHENTICATION_FAILED          => 'storage_unavailable',
    REQUIRED_PASSWORD              => 'storage_unavailable',
    UNKNOWN_DATABASE               => 'storage_unavailable',
    TABLE_IS_READ_ONLY             => 'storage_unavailable',
    NOT_ENOUGH_SPACE               => 'storage_unavailable',

    # The query itself is wrong. These are the only ones the user can fix, so
    # they get a specific (fixed, never echoed) message below.
    SYNTAX_ERROR                   => 'invalid_query',
    CANNOT_COMPILE_REGEXP          => 'invalid_query',
    UNKNOWN_IDENTIFIER             => 'invalid_query',
    ILLEGAL_TYPE_OF_ARGUMENT       => 'invalid_query',
    TYPE_MISMATCH                  => 'invalid_query',
    CANNOT_PARSE_TEXT              => 'invalid_query',
    CANNOT_PARSE_DATE              => 'invalid_query',
    CANNOT_PARSE_DATETIME          => 'invalid_query',
    BAD_ARGUMENTS                  => 'invalid_query',
    TOO_MANY_ROWS                  => 'invalid_query',
    TOO_MANY_BYTES                 => 'invalid_query',
    TOO_MANY_ROWS_OR_BYTES         => 'invalid_query',
);

my %NAME_BY_CODE = (
    6   => 'CANNOT_PARSE_TEXT',
    36  => 'BAD_ARGUMENTS',
    38  => 'CANNOT_PARSE_DATE',
    41  => 'CANNOT_PARSE_DATETIME',
    43  => 'ILLEGAL_TYPE_OF_ARGUMENT',
    47  => 'UNKNOWN_IDENTIFIER',
    53  => 'TYPE_MISMATCH',
    62  => 'SYNTAX_ERROR',
    81  => 'UNKNOWN_DATABASE',
    158 => 'TOO_MANY_ROWS',
    159 => 'TIMEOUT_EXCEEDED',
    173 => 'CANNOT_ALLOCATE_MEMORY',
    194 => 'REQUIRED_PASSWORD',
    202 => 'TOO_MANY_SIMULTANEOUS_QUERIES',
    209 => 'SOCKET_TIMEOUT',
    210 => 'NETWORK_ERROR',
    241 => 'MEMORY_LIMIT_EXCEEDED',
    242 => 'TABLE_IS_READ_ONLY',
    243 => 'NOT_ENOUGH_SPACE',
    252 => 'TOO_MANY_PARTS',
    279 => 'ALL_CONNECTION_TRIES_FAILED',
    307 => 'TOO_MANY_BYTES',
    394 => 'QUERY_WAS_CANCELLED',
    427 => 'CANNOT_COMPILE_REGEXP',
    516 => 'AUTHENTICATION_FAILED',
);

my %INVALID_QUERY_MESSAGE = (
    SYNTAX_ERROR           => 'Query syntax error',
    CANNOT_COMPILE_REGEXP  => 'Invalid regular expression in query',
    UNKNOWN_IDENTIFIER     => 'Unknown field in query',
    TOO_MANY_ROWS          => 'Query matches too much data; narrow the time range or add filters',
    TOO_MANY_BYTES         => 'Query matches too much data; narrow the time range or add filters',
    TOO_MANY_ROWS_OR_BYTES => 'Query matches too much data; narrow the time range or add filters',
);

# classify_clickhouse_error($text)
#
# Returns (class, message) for a ClickHouse / circuit-breaker failure, where
# message is set only for invalid_query (a fixed, user-safe sentence). Returns
# an empty list when $text is not a ClickHouse failure this module recognises.
sub classify_clickhouse_error {
    my ($text) = @_;
    return unless defined $text && length $text;

    return ('storage_unavailable') if $text =~ /ClickHouse circuit breaker is open/;

    # HTTP::Tiny's internal 599: nothing answered at the HTTP level.
    if ($text =~ /ClickHouse (?:insert )?error: 599\b/) {
        return ('query_timeout') if $text =~ /timed?\s*out|timeout/i;
        return ('storage_unavailable');
    }

    return unless $text =~ /ClickHouse (?:insert )?error:|DB::Exception/;

    my ($name) = $text =~ /\(([A-Z][A-Z0-9_]+)\)\s*(?:\(version\b|\z)/m;
    if (!$name || !$CLASS_BY_NAME{$name}) {
        my ($code) = $text =~ /\bCode:\s*(\d+)\./;
        $name = $NAME_BY_CODE{$code} if defined $code && $NAME_BY_CODE{$code};
    }
    return unless $name && $CLASS_BY_NAME{$name};

    my $class = $CLASS_BY_NAME{$name};
    return ($class) unless $class eq 'invalid_query';
    return ($class, $INVALID_QUERY_MESSAGE{$name} // 'Invalid value in query');
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::Errors - map a raw ClickHouse failure to a stable
error class (storage_unavailable, storage_overloaded, query_timeout,
invalid_query) without ever exposing the server's exception text

=cut

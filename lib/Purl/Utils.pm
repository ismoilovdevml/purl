package Purl::Utils;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use URI::Escape ();

our @EXPORT_OK = qw(
    format_duration
    parse_time_range
    epoch_to_iso
    url_encode
);

# Format duration in human readable format
sub format_duration {
    my ($secs) = @_;
    return '0s' unless $secs;

    my @parts;
    if ($secs >= 86400) {
        push @parts, int($secs / 86400) . 'd';
        $secs %= 86400;
    }
    if ($secs >= 3600) {
        push @parts, int($secs / 3600) . 'h';
        $secs %= 3600;
    }
    if ($secs >= 60) {
        push @parts, int($secs / 60) . 'm';
        $secs %= 60;
    }
    if ($secs > 0 && @parts < 2) {
        push @parts, $secs . 's';
    }

    return join(' ', @parts) || '0s';
}

# Parse time range shortcut (15m, 1h, 24h, 7d)
sub parse_time_range {
    my ($range) = @_;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/) {
        $from = $now - ($1 * 86400);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = epoch_to_iso($from);
    my $to_ts = epoch_to_iso($now);

    return ($from_ts, $to_ts);
}

# Convert epoch timestamp to ISO 8601 format
sub epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# URL encode a string
sub url_encode {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

1;

__END__

=head1 NAME

Purl::Utils - Common utility functions for Purl

=head1 SYNOPSIS

    use Purl::Utils qw(
        format_duration
        parse_time_range
        epoch_to_iso
        url_encode
    );

    # Format duration
    my $duration = format_duration(3665);  # "1h 1m"

    # Parse time range
    my ($from, $to) = parse_time_range('24h');

    # Convert epoch to ISO
    my $iso = epoch_to_iso(time());  # "2025-12-15T10:30:00Z"

    # URL encode
    my $encoded = url_encode('hello world');  # "hello%20world"

=head1 DESCRIPTION

This module provides common utility functions used throughout the Purl
application for time formatting, date conversion, and string encoding.

=head1 FUNCTIONS

=head2 format_duration($seconds)

Formats a duration in seconds into a human-readable string.
Returns at most two time units (e.g., "1d 2h", "2h 30m").

=head2 parse_time_range($range)

Parses a time range shortcut string (e.g., "15m", "1h", "24h", "7d")
and returns a pair of ISO 8601 timestamps (from, to).

=head2 epoch_to_iso($epoch)

Converts a Unix epoch timestamp to ISO 8601 format in UTC.

=head2 url_encode($string)

URL-encodes a string according to RFC 3986.

=cut

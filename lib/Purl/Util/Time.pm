package Purl::Util::Time;
use strict;
use warnings;
use Time::HiRes qw(time);
use Time::Piece;
use Exporter 'import';

our @EXPORT_OK = qw(
    epoch_to_iso
    parse_time_range
    format_duration
    to_clickhouse_ts
    now_iso
    now_clickhouse
);

# Convert epoch seconds to ISO8601 format (UTC)
# Example: 1703412600 -> "2024-12-24T10:30:00Z"
sub epoch_to_iso {
    my ($epoch) = @_;
    return '' unless defined $epoch;

    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Parse time range shortcut and return ISO timestamps
# Supported formats: "15m", "1h", "24h", "7d"
# Returns: ($from_iso, $to_iso) or (undef, undef) on invalid input
sub parse_time_range {
    my ($range) = @_;
    return (undef, undef) unless $range;

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

    return (epoch_to_iso($from), epoch_to_iso($now));
}

# Format duration in human readable format
# Example: 90061 -> "1d 1h 1m"
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

# Convert ISO8601 timestamp to ClickHouse DateTime64(3) format
# Example: "2024-12-24T10:30:00Z" -> "2024-12-24 10:30:00.000"
sub to_clickhouse_ts {
    my ($ts) = @_;
    return '' unless $ts;

    # Replace T with space
    $ts =~ s/T/ /;
    # Remove Z suffix
    $ts =~ s/Z$//;
    # Add milliseconds if missing
    $ts .= '.000' unless $ts =~ /\.\d+$/;

    return $ts;
}

# Get current time in ISO8601 format
sub now_iso {
    return epoch_to_iso(time());
}

# Get current time in ClickHouse format
sub now_clickhouse {
    my $t = Time::Piece->new;
    return sprintf('%s.000', $t->strftime('%Y-%m-%d %H:%M:%S'));
}

1;

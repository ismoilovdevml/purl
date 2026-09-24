package Purl::Util::Time;
use strict;
use warnings;
use Time::HiRes qw(time);
use Time::Local qw(timegm);
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

# THE time-bound normaliser (#121). Every from/to a user or shipper sends —
# search, histogram, facets, patterns, traces, dashboards, ingest timestamps —
# goes through here on its way to a ClickHouse DateTime64(3).
#
# Accepts:
#   ISO-8601 with Z / z, +HH:MM, +HHMM, -HH:MM, or no zone (taken as UTC),
#     'T' or space separator, seconds and fraction optional, or a bare date
#   epoch seconds (10 digits, optional fraction) or milliseconds (13 digits)
# Returns UTC 'YYYY-MM-DD HH:MM:SS.fff' (fraction truncated to ms), or '' for
# anything it cannot read as a real instant — callers treat '' as "no bound"
# (and ingest as "use now"), never pass it to ClickHouse.
sub to_clickhouse_ts {
    my ($ts) = @_;
    return '' unless defined $ts && length $ts;
    $ts =~ s/\A\s+|\s+\z//g;

    my ($epoch, $frac);
    if ($ts =~ /\A(\d{13})\z/) {
        ($epoch, $frac) = (int($1 / 1000), sprintf('%03d', $1 % 1000));
    }
    elsif ($ts =~ /\A(\d{9,10})(?:\.(\d+))?\z/) {
        ($epoch, $frac) = ($1, $2 // '');
    }
    elsif ($ts =~ /\A(\d{4})-(\d\d)-(\d\d)
                   (?:[Tt\ ](\d\d):(\d\d)(?::(\d\d)(?:[.,](\d+))?)?)?
                   \s*([Zz]|[+-]\d\d:?\d\d)?\z/x) {
        my ($y, $mo, $d, $h, $mi, $sec, $zone) = ($1, $2, $3, $4 // 0, $5 // 0, $6 // 0, $8);
        $frac = $7 // '';
        return '' if $mo < 1 || $mo > 12 || $d < 1 || $h > 23 || $mi > 59 || $sec > 59;
        $epoch = eval { timegm($sec, $mi, $h, $d, $mo - 1, $y) };
        return '' unless defined $epoch;
        # timegm normalises 2026-02-30 to March 2: refuse instead of guessing.
        my @back = gmtime($epoch);
        return '' unless $back[3] == $d && $back[4] == $mo - 1;
        if (defined $zone && $zone =~ /\A([+-])(\d\d):?(\d\d)\z/) {
            my $off = $2 * 3600 + $3 * 60;
            $epoch += $1 eq '+' ? -$off : $off;
        }
    }
    else {
        return '';
    }

    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d.%s',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0],
        substr($frac . '000', 0, 3));
}

# Get current time in ISO8601 format
sub now_iso {
    return epoch_to_iso(time());
}

# Current time in ClickHouse format — UTC, whatever TZ the host runs in (#109).
sub now_clickhouse {
    my $now = time();
    return to_clickhouse_ts(sprintf('%.3f', $now));
}

1;

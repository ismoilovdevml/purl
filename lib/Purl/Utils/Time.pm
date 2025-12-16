package Purl::Utils::Time;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Time::HiRes ();

our @EXPORT_OK = qw(
    parse_time_range
    parse_time_range_clickhouse
    epoch_to_iso
    epoch_to_clickhouse
    iso_to_epoch
    format_duration
    now_iso
);

our %EXPORT_TAGS = (
    all => \@EXPORT_OK,
);

# Parse time range shortcut (15m, 1h, 24h, 7d) and return ISO timestamps
sub parse_time_range {
    my ($range) = @_;
    return (undef, undef) unless $range;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/i) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/i) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/i) {
        $from = $now - ($1 * 86400);
    }
    elsif ($range =~ /^(\d+)w$/i) {
        $from = $now - ($1 * 604800);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = epoch_to_iso($from);
    my $to_ts = epoch_to_iso($now);

    return ($from_ts, $to_ts);
}

# Convert Unix epoch to ISO 8601 format (UTC)
sub epoch_to_iso {
    my ($epoch) = @_;
    return unless defined $epoch;

    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Convert Unix epoch to ClickHouse DateTime format (YYYY-MM-DD HH:MM:SS)
sub epoch_to_clickhouse {
    my ($epoch) = @_;
    return unless defined $epoch;

    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Parse time range shortcut and return ClickHouse-compatible timestamps
sub parse_time_range_clickhouse {
    my ($range) = @_;
    return (undef, undef) unless $range;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/i) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/i) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/i) {
        $from = $now - ($1 * 86400);
    }
    elsif ($range =~ /^(\d+)w$/i) {
        $from = $now - ($1 * 604800);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = epoch_to_clickhouse($from);
    my $to_ts = epoch_to_clickhouse($now);

    return ($from_ts, $to_ts);
}

# Convert ISO 8601 to Unix epoch
sub iso_to_epoch {
    my ($iso) = @_;
    return unless $iso;

    # Parse ISO 8601 format: 2024-01-15T10:30:00Z or 2024-01-15T10:30:00.123Z
    if ($iso =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z?$/) {
        my ($year, $mon, $day, $hour, $min, $sec) = ($1, $2, $3, $4, $5, $6);

        require Time::Local;
        return Time::Local::timegm($sec, $min, $hour, $day, $mon - 1, $year - 1900);
    }

    return;
}

# Format duration in seconds to human readable string
sub format_duration {
    my ($seconds) = @_;
    return '0s' unless defined $seconds && $seconds > 0;

    my @parts;

    if ($seconds >= 86400) {
        my $days = int($seconds / 86400);
        push @parts, "${days}d";
        $seconds %= 86400;
    }

    if ($seconds >= 3600) {
        my $hours = int($seconds / 3600);
        push @parts, "${hours}h";
        $seconds %= 3600;
    }

    if ($seconds >= 60) {
        my $mins = int($seconds / 60);
        push @parts, "${mins}m";
        $seconds %= 60;
    }

    if ($seconds > 0 && @parts < 2) {
        push @parts, "${seconds}s";
    }

    return join(' ', @parts) || '0s';
}

# Get current time in ISO format
sub now_iso {
    return epoch_to_iso(time());
}

1;

__END__

=head1 NAME

Purl::Utils::Time - Time utility functions for Purl

=head1 SYNOPSIS

    use Purl::Utils::Time qw(parse_time_range epoch_to_iso iso_to_epoch);

    # Parse time range
    my ($from, $to) = parse_time_range('15m');  # Last 15 minutes
    my ($from, $to) = parse_time_range('1h');   # Last 1 hour
    my ($from, $to) = parse_time_range('7d');   # Last 7 days

    # Convert epoch to ISO
    my $iso = epoch_to_iso(time());  # 2024-01-15T10:30:00Z

    # Convert ISO to epoch
    my $epoch = iso_to_epoch('2024-01-15T10:30:00Z');

    # Format duration
    my $str = format_duration(3665);  # "1h 1m"

=head1 DESCRIPTION

This module provides common time-related utility functions used throughout Purl.

=cut

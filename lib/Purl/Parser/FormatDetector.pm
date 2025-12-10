package Purl::Parser::FormatDetector;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();

# Format detection patterns
my %FORMAT_PATTERNS = (
    # JSON logs (must be first - most specific)
    json => qr/^\s*\{.*\}\s*$/,

    # Nginx combined log format
    nginx_combined => qr/^
        \S+\s+-\s+\S+\s+             # remote_addr - remote_user
        \[[^\]]+\]\s+                 # [timestamp]
        "[A-Z]+\s+\S+\s+HTTP\/[\d.]+"  # "METHOD path HTTP/x.x"
        \s+\d{3}\s+\d+                # status bytes
        \s+"[^"]*"\s+"[^"]*"          # "referrer" "user_agent"
    /x,

    # Nginx error log
    nginx_error => qr/^
        \d{4}\/\d{2}\/\d{2}\s+       # date
        \d{2}:\d{2}:\d{2}\s+         # time
        \[\w+\]\s+                    # [level]
        \d+\#\d+:                     # pid#tid:
    /x,

    # Syslog RFC3164
    syslog => qr/^
        (?:<\d+>)?                    # optional priority
        [A-Z][a-z]{2}\s+\d+\s+        # Month Day
        \d{2}:\d{2}:\d{2}\s+          # time
        \S+\s+                        # hostname
        \S+                           # program
    /x,

    # Syslog RFC5424
    syslog_rfc5424 => qr/^
        <\d+>\d+\s+                   # priority and version
        \d{4}-\d{2}-\d{2}T            # ISO timestamp start
    /x,

    # Docker JSON logs
    docker_json => qr/^
        \{"log":".*",
        "stream":"(?:stdout|stderr)",
        "time":"
    /x,

    # Apache/NCSA Combined Log Format (CLF)
    clf => qr/^
        \S+\s+\S+\s+\S+\s+           # host ident user
        \[[^\]]+\]\s+                 # [timestamp]
        "[^"]*"\s+                    # "request"
        \d{3}\s+                      # status
        (?:\d+|-)                     # bytes
    /x,

    # Apache error log
    apache_error => qr/^
        \[[A-Z][a-z]{2}\s+[A-Z][a-z]{2}\s+\d+\s+  # [Day Mon DD
        \d{2}:\d{2}:\d{2}(?:\.\d+)?\s+\d{4}\]     # HH:MM:SS.ms YYYY]
    /x,

    # Kubernetes/container logs with timestamp prefix
    kubernetes => qr/^
        \d{4}-\d{2}-\d{2}T           # ISO date
        \d{2}:\d{2}:\d{2}            # time
        (?:\.\d+)?Z?\s+              # optional ms and Z
        (?:stdout|stderr)\s+         # stream
        [FP]\s+                      # full/partial flag
    /x,

    # PostgreSQL
    postgresql => qr/^
        \d{4}-\d{2}-\d{2}\s+         # date
        \d{2}:\d{2}:\d{2}            # time
        (?:\.\d+)?\s+                # optional ms
        \w+\s+                       # timezone
        \[\d+\]                      # [pid]
    /x,

    # Python logging default format
    python => qr/^
        \d{4}-\d{2}-\d{2}\s+         # date
        \d{2}:\d{2}:\d{2},\d{3}\s+   # time with ms
        -\s+\w+\s+-                  # - LEVEL -
    /x,

    # Java/Log4j
    log4j => qr/^
        \d{4}-\d{2}-\d{2}\s+         # date
        \d{2}:\d{2}:\d{2}[,\.]\d{3}\s+  # time with ms
        (?:\[[\w\-]+\]\s+)?          # optional thread
        \b(?:TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\b
    /x,

    # Go standard log
    go_log => qr/^
        \d{4}\/\d{2}\/\d{2}\s+       # date with /
        \d{2}:\d{2}:\d{2}\s+         # time
    /x,

    # Generic ISO timestamp with level
    generic_iso => qr/^
        \d{4}-\d{2}-\d{2}[T\s]       # ISO date
        \d{2}:\d{2}:\d{2}            # time
        [^\[]*                       # anything before level
        \b(?:TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL|CRITICAL)\b
    /xi,
);

# Confidence weights for each format
my %FORMAT_WEIGHTS = (
    json           => 100,
    docker_json    => 95,
    nginx_combined => 90,
    nginx_error    => 90,
    kubernetes     => 85,
    syslog_rfc5424 => 85,
    syslog         => 80,
    postgresql     => 80,
    apache_error   => 75,
    log4j          => 70,
    python         => 70,
    clf            => 65,
    go_log         => 60,
    generic_iso    => 50,
);

has 'sample_lines' => (
    is      => 'ro',
    default => sub { 10 },
);

has '_detection_cache' => (
    is      => 'rw',
    default => sub { {} },
);

# Detect format from a single line
sub detect_line {
    my ($self, $line) = @_;

    return unless defined $line && length $line;

    # Check cache first
    my $cache_key = substr($line, 0, 100);
    if (exists $self->_detection_cache->{$cache_key}) {
        return $self->_detection_cache->{$cache_key};
    }

    my $best_format;
    my $best_weight = 0;

    for my $format (keys %FORMAT_PATTERNS) {
        if ($line =~ $FORMAT_PATTERNS{$format}) {
            my $weight = $FORMAT_WEIGHTS{$format} // 50;
            if ($weight > $best_weight) {
                $best_weight = $weight;
                $best_format = $format;
            }
        }
    }

    # Additional JSON validation
    if ($best_format && $best_format eq 'json') {
        eval { JSON::XS::decode_json($line) };
        if ($@) {
            # Not valid JSON, try other formats
            $best_format = undef;
            $best_weight = 0;
            for my $format (grep { $_ ne 'json' } keys %FORMAT_PATTERNS) {
                if ($line =~ $FORMAT_PATTERNS{$format}) {
                    my $weight = $FORMAT_WEIGHTS{$format} // 50;
                    if ($weight > $best_weight) {
                        $best_weight = $weight;
                        $best_format = $format;
                    }
                }
            }
        }
    }

    $best_format //= 'unknown';

    # Cache result
    $self->_detection_cache->{$cache_key} = $best_format;

    return $best_format;
}

# Detect format from multiple lines (more accurate)
sub detect_lines {
    my ($self, $lines) = @_;

    my %format_counts;
    my $total = 0;

    for my $line (@$lines) {
        next unless defined $line && $line =~ /\S/;
        my $format = $self->detect_line($line);
        $format_counts{$format}++;
        $total++;
        last if $total >= $self->sample_lines;
    }

    return 'unknown' unless $total;

    # Find most common format
    my ($best_format) = sort {
        $format_counts{$b} <=> $format_counts{$a}
    } keys %format_counts;

    return $best_format;
}

# Detect format from file
sub detect_file {
    my ($self, $filepath) = @_;

    open my $fh, '<', $filepath or die "Cannot open $filepath: $!";

    my @lines;
    while (my $line = <$fh>) {
        chomp $line;
        push @lines, $line;
        last if @lines >= $self->sample_lines;
    }

    close $fh;

    return $self->detect_lines(\@lines);
}

# Get list of supported formats
sub supported_formats {
    return sort keys %FORMAT_PATTERNS;
}

# Get pattern for a format
sub get_pattern {
    my ($self, $format) = @_;
    return $FORMAT_PATTERNS{$format};
}

# Check if a format is supported
sub is_supported {
    my ($self, $format) = @_;
    return exists $FORMAT_PATTERNS{$format};
}

# Clear detection cache
sub clear_cache {
    my ($self) = @_;
    $self->_detection_cache({});
}

1;

__END__

=head1 NAME

Purl::Parser::FormatDetector - Auto-detect log format

=head1 SYNOPSIS

    use Purl::Parser::FormatDetector;

    my $detector = Purl::Parser::FormatDetector->new();

    # Detect from single line
    my $format = $detector->detect_line($log_line);

    # Detect from file
    my $format = $detector->detect_file('/var/log/nginx/access.log');

=head1 DESCRIPTION

Automatically detects log formats using pattern matching.
Supports nginx, syslog, JSON, Docker, CLF, and many more formats.

=cut

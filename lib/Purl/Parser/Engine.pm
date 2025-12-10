package Purl::Parser::Engine;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use Time::Piece;
use Purl::Parser::FormatDetector;

has 'detector' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Purl::Parser::FormatDetector->new() },
);

has 'custom_patterns' => (
    is      => 'rw',
    default => sub { {} },
);

# Built-in parsing patterns with named captures
my %PARSERS = (
    json => \&_parse_json,
    nginx_combined => \&_parse_nginx_combined,
    nginx_error => \&_parse_nginx_error,
    syslog => \&_parse_syslog,
    syslog_rfc5424 => \&_parse_syslog_rfc5424,
    docker_json => \&_parse_docker_json,
    clf => \&_parse_clf,
    apache_error => \&_parse_apache_error,
    kubernetes => \&_parse_kubernetes,
    postgresql => \&_parse_postgresql,
    python => \&_parse_python,
    log4j => \&_parse_log4j,
    go_log => \&_parse_go_log,
    generic_iso => \&_parse_generic_iso,
);

# Parse a single line
sub parse {
    my ($self, $line, $format) = @_;

    return unless defined $line && $line =~ /\S/;

    # Auto-detect format if not provided
    $format //= $self->detector->detect_line($line);

    # Try custom pattern first
    if ($format && exists $self->custom_patterns->{$format}) {
        my $result = $self->_parse_with_pattern($line, $self->custom_patterns->{$format});
        return $result if $result;
    }

    # Try built-in parser
    if ($format && exists $PARSERS{$format}) {
        my $result = $PARSERS{$format}->($self, $line);
        return $result if $result;
    }

    # Fallback: return raw line
    return {
        raw     => $line,
        message => $line,
        _format => 'raw',
    };
}

# Parse multiple lines
sub parse_lines {
    my ($self, $lines, $format) = @_;

    # Detect format from first few lines if not provided
    unless ($format) {
        $format = $self->detector->detect_lines($lines);
    }

    my @results;
    for my $line (@$lines) {
        my $parsed = $self->parse($line, $format);
        push @results, $parsed if $parsed;
    }

    return \@results;
}

# Add custom pattern
sub add_pattern {
    my ($self, $name, $pattern) = @_;
    $self->custom_patterns->{$name} = $pattern;
}

# Parse with custom regex pattern
sub _parse_with_pattern {
    my ($self, $line, $pattern) = @_;

    if ($line =~ $pattern) {
        my %captures = %+;  # Named captures
        return {
            %captures,
            raw     => $line,
            _format => 'custom',
        };
    }

    return;
}

# JSON parser
sub _parse_json {
    my ($self, $line) = @_;

    my $data;
    eval { $data = JSON::XS::decode_json($line) };
    return if $@;

    return {
        %$data,
        raw     => $line,
        _format => 'json',
    };
}

# Nginx combined log format
sub _parse_nginx_combined {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<remote_ip>\S+)\s+-\s+
        (?<remote_user>\S+)\s+
        \[(?<timestamp>[^\]]+)\]\s+
        "(?<method>\S+)\s+(?<path>\S+)\s+(?<protocol>[^"]+)"\s+
        (?<status>\d+)\s+
        (?<bytes>\d+)\s+
        "(?<referrer>[^"]*)"\s+
        "(?<user_agent>[^"]*)"
        (?:\s+"(?<x_forwarded_for>[^"]*)")?
    /x;

    if ($line =~ $pattern) {
        return {
            remote_ip    => $+{remote_ip},
            remote_user  => $+{remote_user} eq '-' ? undef : $+{remote_user},
            timestamp    => $self->_parse_nginx_timestamp($+{timestamp}),
            method       => $+{method},
            path         => $+{path},
            protocol     => $+{protocol},
            status       => int($+{status}),
            bytes        => int($+{bytes}),
            referrer     => $+{referrer} eq '-' ? undef : $+{referrer},
            user_agent   => $+{user_agent},
            x_forwarded_for => $+{x_forwarded_for},
            raw          => $line,
            _format      => 'nginx_combined',
        };
    }

    return;
}

# Nginx error log
sub _parse_nginx_error {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2})\s+
        \[(?<level>\w+)\]\s+
        (?<pid>\d+)\#(?<tid>\d+):\s+
        (?:\*(?<cid>\d+)\s+)?
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $self->_parse_nginx_error_timestamp($+{timestamp}),
            level     => uc($+{level}),
            pid       => int($+{pid}),
            tid       => int($+{tid}),
            cid       => $+{cid} ? int($+{cid}) : undef,
            message   => $+{message},
            raw       => $line,
            _format   => 'nginx_error',
        };
    }

    return;
}

# Syslog RFC3164
sub _parse_syslog {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?:<(?<priority>\d+)>)?
        (?<timestamp>[A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+
        (?<host>\S+)\s+
        (?<program>[^\[:]+)
        (?:\[(?<pid>\d+)\])?:\s*
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        my $priority = $+{priority};
        my ($facility, $severity);
        if (defined $priority) {
            $facility = int($priority / 8);
            $severity = $priority % 8;
        }

        return {
            timestamp => $self->_parse_syslog_timestamp($+{timestamp}),
            host      => $+{host},
            program   => $+{program},
            pid       => $+{pid} ? int($+{pid}) : undef,
            message   => $+{message},
            facility  => $facility,
            severity  => $severity,
            level     => $self->_severity_to_level($severity),
            raw       => $line,
            _format   => 'syslog',
        };
    }

    return;
}

# Syslog RFC5424
sub _parse_syslog_rfc5424 {
    my ($self, $line) = @_;

    my $pattern = qr/^
        <(?<priority>\d+)>(?<version>\d+)\s+
        (?<timestamp>\S+)\s+
        (?<host>\S+)\s+
        (?<app>\S+)\s+
        (?<procid>\S+)\s+
        (?<msgid>\S+)\s+
        (?<structured>(?:\[.*?\])*|-)\s*
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        my $priority = int($+{priority});
        my $facility = int($priority / 8);
        my $severity = $priority % 8;

        return {
            timestamp  => $+{timestamp},
            host       => $+{host} eq '-' ? undef : $+{host},
            app        => $+{app} eq '-' ? undef : $+{app},
            procid     => $+{procid} eq '-' ? undef : $+{procid},
            msgid      => $+{msgid} eq '-' ? undef : $+{msgid},
            structured => $+{structured} eq '-' ? undef : $+{structured},
            message    => $+{message},
            facility   => $facility,
            severity   => $severity,
            level      => $self->_severity_to_level($severity),
            raw        => $line,
            _format    => 'syslog_rfc5424',
        };
    }

    return;
}

# Docker JSON log
sub _parse_docker_json {
    my ($self, $line) = @_;

    my $data;
    eval { $data = JSON::XS::decode_json($line) };
    return if $@;

    return unless $data->{log} && $data->{stream};

    # Clean up the log message (remove trailing newline)
    my $message = $data->{log};
    $message =~ s/\n$//;

    return {
        timestamp => $data->{time},
        message   => $message,
        stream    => $data->{stream},
        raw       => $line,
        _format   => 'docker_json',
    };
}

# Apache/NCSA CLF
sub _parse_clf {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<remote_ip>\S+)\s+
        (?<ident>\S+)\s+
        (?<remote_user>\S+)\s+
        \[(?<timestamp>[^\]]+)\]\s+
        "(?<request>[^"]*)"\s+
        (?<status>\d+)\s+
        (?<bytes>\S+)
    /x;

    if ($line =~ $pattern) {
        my ($method, $path, $protocol) = split /\s+/, $+{request}, 3;

        return {
            remote_ip   => $+{remote_ip},
            ident       => $+{ident} eq '-' ? undef : $+{ident},
            remote_user => $+{remote_user} eq '-' ? undef : $+{remote_user},
            timestamp   => $self->_parse_clf_timestamp($+{timestamp}),
            method      => $method,
            path        => $path,
            protocol    => $protocol,
            status      => int($+{status}),
            bytes       => $+{bytes} eq '-' ? 0 : int($+{bytes}),
            raw         => $line,
            _format     => 'clf',
        };
    }

    return;
}

# Apache error log
sub _parse_apache_error {
    my ($self, $line) = @_;

    my $pattern = qr/^
        \[(?<timestamp>[^\]]+)\]\s+
        \[(?:(?<module>\w+):)?(?<level>\w+)\]\s+
        \[pid\s+(?<pid>\d+)(?::tid\s+(?<tid>\d+))?\]\s*
        (?:\[client\s+(?<client>[^\]]+)\]\s+)?
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            module    => $+{module},
            level     => uc($+{level}),
            pid       => int($+{pid}),
            tid       => $+{tid} ? int($+{tid}) : undef,
            client    => $+{client},
            message   => $+{message},
            raw       => $line,
            _format   => 'apache_error',
        };
    }

    return;
}

# Kubernetes log format
sub _parse_kubernetes {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?)\s+
        (?<stream>stdout|stderr)\s+
        (?<flag>[FP])\s+
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            stream    => $+{stream},
            partial   => $+{flag} eq 'P' ? 1 : 0,
            message   => $+{message},
            raw       => $line,
            _format   => 'kubernetes',
        };
    }

    return;
}

# PostgreSQL log
sub _parse_postgresql {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+
        (?<timezone>\w+)\s+
        \[(?<pid>\d+)\]\s+
        (?:(?<user>\w+)@(?<database>\w+)\s+)?
        (?<level>\w+):\s+
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            timezone  => $+{timezone},
            pid       => int($+{pid}),
            user      => $+{user},
            database  => $+{database},
            level     => uc($+{level}),
            message   => $+{message},
            raw       => $line,
            _format   => 'postgresql',
        };
    }

    return;
}

# Python logging
sub _parse_python {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2},\d{3})\s+
        -\s+(?<level>\w+)\s+-\s+
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            level     => uc($+{level}),
            message   => $+{message},
            raw       => $line,
            _format   => 'python',
        };
    }

    return;
}

# Log4j format
sub _parse_log4j {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}[,\.]\d{3})\s+
        (?:\[(?<thread>[^\]]+)\]\s+)?
        (?<level>TRACE|DEBUG|INFO|WARN|ERROR|FATAL)\s+
        (?:(?<logger>[\w\.]+)\s+-\s+)?
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            thread    => $+{thread},
            level     => uc($+{level}),
            logger    => $+{logger},
            message   => $+{message},
            raw       => $line,
            _format   => 'log4j',
        };
    }

    return;
}

# Go standard log
sub _parse_go_log {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}\/\d{2}\/\d{2}\s+\d{2}:\d{2}:\d{2})\s+
        (?:(?<file>[^:]+):(?<line>\d+):\s+)?
        (?<message>.*)
    /x;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            file      => $+{file},
            line      => $+{line} ? int($+{line}) : undef,
            message   => $+{message},
            raw       => $line,
            _format   => 'go_log',
        };
    }

    return;
}

# Generic ISO timestamp with level
sub _parse_generic_iso {
    my ($self, $line) = @_;

    my $pattern = qr/^
        (?<timestamp>\d{4}-\d{2}-\d{2}[T\s]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+
        (?:.*?\s)?
        (?<level>TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL|CRITICAL)\s+
        (?<message>.*)
    /xi;

    if ($line =~ $pattern) {
        return {
            timestamp => $+{timestamp},
            level     => uc($+{level}),
            message   => $+{message},
            raw       => $line,
            _format   => 'generic_iso',
        };
    }

    return;
}

# Timestamp parsing helpers
sub _parse_nginx_timestamp {
    my ($self, $ts) = @_;
    # Format: 10/Dec/2024:10:23:45 +0000
    my $t = eval { Time::Piece->strptime($ts, '%d/%b/%Y:%H:%M:%S %z') };
    return $t ? $t->datetime . 'Z' : $ts;
}

sub _parse_nginx_error_timestamp {
    my ($self, $ts) = @_;
    # Format: 2024/12/10 10:23:45
    my $t = eval { Time::Piece->strptime($ts, '%Y/%m/%d %H:%M:%S') };
    return $t ? $t->datetime . 'Z' : $ts;
}

sub _parse_syslog_timestamp {
    my ($self, $ts) = @_;
    # Format: Dec 10 10:23:45 (no year!)
    my $year = (localtime)[5] + 1900;
    my $t = eval { Time::Piece->strptime("$ts $year", '%b %d %H:%M:%S %Y') };
    return $t ? $t->datetime . 'Z' : $ts;
}

sub _parse_clf_timestamp {
    my ($self, $ts) = @_;
    # Format: 10/Dec/2024:10:23:45 +0000
    return $self->_parse_nginx_timestamp($ts);
}

# Convert syslog severity to level name
sub _severity_to_level {
    my ($self, $severity) = @_;
    return unless defined $severity;

    my @levels = qw(EMERGENCY ALERT CRITICAL ERROR WARNING NOTICE INFO DEBUG);
    return $levels[$severity] // 'UNKNOWN';
}

1;

__END__

=head1 NAME

Purl::Parser::Engine - Parse log lines into structured data

=head1 SYNOPSIS

    use Purl::Parser::Engine;

    my $parser = Purl::Parser::Engine->new();

    # Parse single line (auto-detect format)
    my $data = $parser->parse($log_line);

    # Parse with specific format
    my $data = $parser->parse($log_line, 'nginx_combined');

    # Add custom pattern
    $parser->add_pattern('myapp', qr/^(?<ts>\S+) (?<level>\w+) (?<msg>.*)/);

=cut

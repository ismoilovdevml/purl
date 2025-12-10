package Purl::Parser::Normalizer;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use Time::Piece;
use Scalar::Util qw(looks_like_number);

# Field mapping configuration
has 'timestamp_fields' => (
    is      => 'rw',
    default => sub { [qw(timestamp time @timestamp date datetime ts)] },
);

has 'level_fields' => (
    is      => 'rw',
    default => sub { [qw(level severity log_level loglevel priority)] },
);

has 'message_fields' => (
    is      => 'rw',
    default => sub { [qw(message msg log text body content)] },
);

has 'host_fields' => (
    is      => 'rw',
    default => sub { [qw(host hostname server node)] },
);

has 'service_fields' => (
    is      => 'rw',
    default => sub { [qw(service app application program logger source)] },
);

# Level normalization mapping
has 'level_mapping' => (
    is      => 'rw',
    default => sub {
        {
            # Emergency
            emerg     => 'EMERGENCY',
            emergency => 'EMERGENCY',
            panic     => 'EMERGENCY',

            # Alert
            alert => 'ALERT',

            # Critical
            crit     => 'CRITICAL',
            critical => 'CRITICAL',
            fatal    => 'CRITICAL',

            # Error
            err   => 'ERROR',
            error => 'ERROR',
            fail  => 'ERROR',
            failed => 'ERROR',

            # Warning
            warn    => 'WARNING',
            warning => 'WARNING',

            # Notice
            notice => 'NOTICE',

            # Info
            info        => 'INFO',
            information => 'INFO',

            # Debug
            debug => 'DEBUG',
            dbg   => 'DEBUG',

            # Trace
            trace => 'TRACE',
            verbose => 'TRACE',
        }
    },
);

# Default tags to add to all logs
has 'default_tags' => (
    is      => 'rw',
    default => sub { {} },
);

# JSON encoder for meta field
has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical },
);

# Normalize parsed log data to unified schema
sub normalize {
    my ($self, $parsed, $extra_tags) = @_;

    return unless $parsed && ref $parsed eq 'HASH';

    my $normalized = {
        timestamp => $self->_extract_timestamp($parsed),
        level     => $self->_extract_level($parsed),
        service   => $self->_extract_service($parsed),
        host      => $self->_extract_host($parsed),
        message   => $self->_extract_message($parsed),
        raw       => $parsed->{raw} // '',
        meta      => {},
    };

    # Collect all other fields into meta
    my %seen = map { $_ => 1 } @{$self->timestamp_fields},
                               @{$self->level_fields},
                               @{$self->message_fields},
                               @{$self->host_fields},
                               @{$self->service_fields},
                               qw(raw _format);

    for my $key (keys %$parsed) {
        next if $seen{$key};
        next unless defined $parsed->{$key};
        $normalized->{meta}{$key} = $parsed->{$key};
    }

    # Add tags
    my $tags = { %{$self->default_tags}, %{$extra_tags // {}} };
    if (%$tags) {
        $normalized->{meta}{tags} = $tags;
    }

    # Store original format
    if ($parsed->{_format}) {
        $normalized->{meta}{_source_format} = $parsed->{_format};
    }

    return $normalized;
}

# Extract timestamp from parsed data
sub _extract_timestamp {
    my ($self, $parsed) = @_;

    # Try each timestamp field
    for my $field (@{$self->timestamp_fields}) {
        next unless exists $parsed->{$field} && defined $parsed->{$field};
        my $ts = $self->_normalize_timestamp($parsed->{$field});
        return $ts if $ts;
    }

    # Default to current time
    return $self->_current_iso_timestamp();
}

# Normalize various timestamp formats to ISO8601
sub _normalize_timestamp {
    my ($self, $ts) = @_;

    return unless defined $ts;

    # Already ISO8601
    if ($ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/) {
        # Ensure it ends with Z or timezone
        $ts =~ s/Z$//;
        $ts =~ s/[+-]\d{2}:?\d{2}$//;
        return "${ts}Z" if $ts =~ /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;
    }

    # Unix timestamp (seconds)
    if ($ts =~ /^(\d{10})(?:\.(\d+))?$/) {
        my $t = Time::Piece->new($1);
        my $ms = $2 ? ".$2" : '';
        return $t->datetime . "${ms}Z";
    }

    # Unix timestamp (milliseconds)
    if ($ts =~ /^(\d{13})$/) {
        my $t = Time::Piece->new(int($1 / 1000));
        my $ms = $1 % 1000;
        return sprintf('%sT%s.%03dZ', $t->ymd, $t->hms, $ms);
    }

    # Common date formats
    my @formats = (
        '%Y-%m-%d %H:%M:%S',      # 2024-12-10 10:23:45
        '%Y/%m/%d %H:%M:%S',      # 2024/12/10 10:23:45
        '%d/%b/%Y:%H:%M:%S',      # 10/Dec/2024:10:23:45
        '%b %d %H:%M:%S',         # Dec 10 10:23:45
        '%Y-%m-%d %H:%M:%S,%N',   # Python: 2024-12-10 10:23:45,123
    );

    for my $fmt (@formats) {
        my $t = eval { Time::Piece->strptime($ts, $fmt) };
        if ($t) {
            return $t->datetime . 'Z';
        }
    }

    # Return original if parsing failed
    return $ts;
}

# Get current timestamp in ISO8601
sub _current_iso_timestamp {
    my ($self) = @_;
    my $t = Time::Piece->new;
    return $t->datetime . 'Z';
}

# Extract log level
sub _extract_level {
    my ($self, $parsed) = @_;

    # Try each level field
    for my $field (@{$self->level_fields}) {
        next unless exists $parsed->{$field} && defined $parsed->{$field};
        return $self->_normalize_level($parsed->{$field});
    }

    # Try to extract from HTTP status code
    if (exists $parsed->{status}) {
        return $self->_status_to_level($parsed->{status});
    }

    # Default level
    return 'INFO';
}

# Normalize level names
sub _normalize_level {
    my ($self, $level) = @_;

    return 'INFO' unless defined $level;

    # Already uppercase and known
    my $lower = lc($level);

    if (exists $self->level_mapping->{$lower}) {
        return $self->level_mapping->{$lower};
    }

    # Handle syslog numeric severity
    if (looks_like_number($level) && $level >= 0 && $level <= 7) {
        my @levels = qw(EMERGENCY ALERT CRITICAL ERROR WARNING NOTICE INFO DEBUG);
        return $levels[$level];
    }

    # Return uppercase original
    return uc($level);
}

# Convert HTTP status to level
sub _status_to_level {
    my ($self, $status) = @_;

    return 'INFO' unless looks_like_number($status);

    if ($status >= 500) {
        return 'ERROR';
    } elsif ($status >= 400) {
        return 'WARNING';
    } elsif ($status >= 300) {
        return 'INFO';
    } else {
        return 'INFO';
    }
}

# Extract service/application name
sub _extract_service {
    my ($self, $parsed) = @_;

    for my $field (@{$self->service_fields}) {
        next unless exists $parsed->{$field} && defined $parsed->{$field};
        return $parsed->{$field};
    }

    return 'unknown';
}

# Extract hostname
sub _extract_host {
    my ($self, $parsed) = @_;

    for my $field (@{$self->host_fields}) {
        next unless exists $parsed->{$field} && defined $parsed->{$field};
        return $parsed->{$field};
    }

    # Try to get local hostname
    require Sys::Hostname;
    return Sys::Hostname::hostname() // 'localhost';
}

# Extract message
sub _extract_message {
    my ($self, $parsed) = @_;

    for my $field (@{$self->message_fields}) {
        next unless exists $parsed->{$field} && defined $parsed->{$field};
        return $parsed->{$field};
    }

    # Fallback to raw line
    return $parsed->{raw} // '';
}

# Convert normalized log to flat structure for database
sub to_flat {
    my ($self, $normalized) = @_;

    return {
        timestamp => $normalized->{timestamp},
        level     => $normalized->{level},
        service   => $normalized->{service},
        host      => $normalized->{host},
        message   => $normalized->{message},
        raw       => $normalized->{raw},
        meta_json => $self->_json->encode($normalized->{meta} // {}),
    };
}

# Convert flat structure back to normalized
sub from_flat {
    my ($self, $flat) = @_;

    return {
        timestamp => $flat->{timestamp},
        level     => $flat->{level},
        service   => $flat->{service},
        host      => $flat->{host},
        message   => $flat->{message},
        raw       => $flat->{raw},
        meta      => eval { $self->_json->decode($flat->{meta_json} // '{}') } // {},
    };
}

1;

__END__

=head1 NAME

Purl::Parser::Normalizer - Normalize parsed logs to unified schema

=head1 SYNOPSIS

    use Purl::Parser::Normalizer;

    my $normalizer = Purl::Parser::Normalizer->new(
        default_tags => { env => 'production' },
    );

    my $normalized = $normalizer->normalize($parsed_data);

    # Result:
    # {
    #     timestamp => '2024-12-10T10:23:45Z',
    #     level     => 'ERROR',
    #     service   => 'nginx',
    #     host      => 'server-01',
    #     message   => 'Connection refused',
    #     raw       => 'original log line',
    #     meta      => { ... additional fields ... },
    # }

=cut

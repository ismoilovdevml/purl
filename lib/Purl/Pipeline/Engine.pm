package Purl::Pipeline::Engine;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

# ============================================
# Pipeline processing engine
# Applies ordered rules to log entries during
# ingestion for parsing and enrichment.
# ============================================

has 'pipelines' => (
    is      => 'rw',
    default => sub { [] },
);

# Apply all enabled pipelines to a log entry
# Returns undef if log should be dropped
sub process {
    my ($self, $log) = @_;
    return $log unless @{ $self->pipelines };

    for my $pipeline (@{ $self->pipelines }) {
        next unless $pipeline->{enabled};

        # Check if pipeline matches this log (by service filter)
        if (my $filter_service = $pipeline->{filter_service}) {
            next unless ($log->{service} // '') =~ /^$filter_service$/i;
        }

        for my $rule (@{ $pipeline->{rules} // [] }) {
            next unless $rule->{enabled} // 1;
            $log = _apply_rule($log, $rule);
            return undef unless defined $log;  # Drop rule
        }
    }

    return $log;
}

# Test a pipeline against sample data without persisting
sub test_pipeline {
    my ($self, $pipeline, $sample_logs) = @_;
    my @results;

    for my $log (@$sample_logs) {
        my $input  = { %$log };
        my $output = { %$log };

        for my $rule (@{ $pipeline->{rules} // [] }) {
            next unless $rule->{enabled} // 1;
            $output = _apply_rule($output, $rule);
            last unless defined $output;
        }

        push @results, {
            input   => $input,
            output  => $output,
            dropped => !defined $output,
        };
    }

    return \@results;
}

# ============================================
# Rule application
# ============================================

sub _apply_rule {
    my ($log, $rule) = @_;
    my $type = $rule->{type} // '';

    if ($type eq 'regex') {
        return _rule_regex($log, $rule);
    } elsif ($type eq 'json_extract') {
        return _rule_json_extract($log, $rule);
    } elsif ($type eq 'drop') {
        return _rule_drop($log, $rule);
    } elsif ($type eq 'mutate') {
        return _rule_mutate($log, $rule);
    } elsif ($type eq 'grok') {
        return _rule_grok($log, $rule);
    }

    return $log;  # Unknown rule type, pass through
}

# Regex: extract named captures from a field
sub _rule_regex {
    my ($log, $rule) = @_;
    my $source  = $rule->{source_field} // 'message';
    my $pattern = $rule->{pattern}      // '';

    return $log unless $pattern;

    my $value = $log->{$source} // $log->{meta}{$source} // '';

    if (my @captures = $value =~ qr/$pattern/) {
        # Named captures go to meta
        my %named = %+;
        if (%named) {
            $log->{meta} //= {};
            for my $key (keys %named) {
                $log->{meta}{$key} = $named{$key} if defined $named{$key};
            }
        }
    }

    return $log;
}

# JSON extract: parse JSON from a field and promote keys
sub _rule_json_extract {
    my ($log, $rule) = @_;
    my $source = $rule->{source_field} // 'message';

    my $value = $log->{$source} // $log->{meta}{$source} // '';
    my $parsed = eval { decode_json($value) };
    return $log unless $parsed && ref $parsed eq 'HASH';

    $log->{meta} //= {};

    # Promote specified keys or all
    my @keys = $rule->{keys} ? @{ $rule->{keys} } : keys %$parsed;
    for my $key (@keys) {
        next unless exists $parsed->{$key};

        my $target = $rule->{target_prefix} ? "$rule->{target_prefix}.$key" : $key;

        # Promote well-known fields to top level
        if ($key eq 'level' || $key eq 'severity') {
            $log->{level} = uc($parsed->{$key});
        } elsif ($key eq 'service' || $key eq 'app' || $key eq 'application') {
            $log->{service} = $parsed->{$key};
        } elsif ($key eq 'host' || $key eq 'hostname') {
            $log->{host} = $parsed->{$key};
        } elsif ($key eq 'message' || $key eq 'msg') {
            $log->{message} = $parsed->{$key} unless $source eq 'message';
        } elsif ($key eq 'timestamp' || $key eq 'time' || $key eq 'ts') {
            $log->{timestamp} = $parsed->{$key};
        } else {
            $log->{meta}{$target} = ref $parsed->{$key}
                ? encode_json($parsed->{$key})
                : $parsed->{$key};
        }
    }

    return $log;
}

# Drop: discard log if condition matches
sub _rule_drop {
    my ($log, $rule) = @_;
    my $field   = $rule->{field}   // 'message';
    my $pattern = $rule->{pattern} // '';

    return $log unless $pattern;

    my $value = $log->{$field} // $log->{meta}{$field} // '';

    if ($value =~ qr/$pattern/i) {
        return undef;  # Signal to drop this log
    }

    return $log;
}

# Mutate: modify field values
sub _rule_mutate {
    my ($log, $rule) = @_;
    my $action = $rule->{action} // '';

    if ($action eq 'rename' && $rule->{from} && $rule->{to}) {
        if (exists $log->{ $rule->{from} }) {
            $log->{ $rule->{to} } = delete $log->{ $rule->{from} };
        } elsif ($log->{meta} && exists $log->{meta}{ $rule->{from} }) {
            $log->{meta}{ $rule->{to} } = delete $log->{meta}{ $rule->{from} };
        }
    } elsif ($action eq 'remove' && $rule->{field}) {
        delete $log->{meta}{ $rule->{field} } if $log->{meta};
    } elsif ($action eq 'set' && $rule->{field} && defined $rule->{value}) {
        if ($rule->{field} =~ /^(level|service|host|message)$/) {
            $log->{ $rule->{field} } = $rule->{value};
        } else {
            $log->{meta} //= {};
            $log->{meta}{ $rule->{field} } = $rule->{value};
        }
    } elsif ($action eq 'lowercase' && $rule->{field}) {
        my $f = $rule->{field};
        if (exists $log->{$f}) {
            $log->{$f} = lc($log->{$f});
        } elsif ($log->{meta} && exists $log->{meta}{$f}) {
            $log->{meta}{$f} = lc($log->{meta}{$f});
        }
    } elsif ($action eq 'uppercase' && $rule->{field}) {
        my $f = $rule->{field};
        if (exists $log->{$f}) {
            $log->{$f} = uc($log->{$f});
        } elsif ($log->{meta} && exists $log->{meta}{$f}) {
            $log->{meta}{$f} = uc($log->{meta}{$f});
        }
    }

    return $log;
}

# Grok: common patterns (simplified — no full grok grammar)
sub _rule_grok {
    my ($log, $rule) = @_;
    my $source  = $rule->{source_field} // 'message';
    my $pattern = $rule->{pattern}      // '';

    return $log unless $pattern;

    # Replace common grok patterns with regex equivalents
    my %grok_patterns = (
        '%{IP:ip}'              => '(?<ip>\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3})',
        '%{NUMBER:number}'      => '(?<number>[\\d.]+)',
        '%{WORD:word}'          => '(?<word>\\w+)',
        '%{DATA:data}'          => '(?<data>.*?)',
        '%{GREEDYDATA:message}' => '(?<message>.*)',
        '%{TIMESTAMP_ISO8601:timestamp}' => '(?<timestamp>\\d{4}-\\d{2}-\\d{2}[T ]\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?(?:Z|[+-]\\d{2}:\\d{2})?)',
        '%{LOGLEVEL:level}'     => '(?<level>(?:TRACE|DEBUG|INFO|WARN(?:ING)?|ERROR|FATAL|CRITICAL))',
    );

    # Also handle generic %{PATTERN:name} syntax
    my $regex = $pattern;
    for my $grok_key (keys %grok_patterns) {
        my $grok_escaped = quotemeta($grok_key);
        $regex =~ s/$grok_escaped/$grok_patterns{$grok_key}/g;
    }

    # Handle remaining %{WORD:name} patterns as generic word capture
    $regex =~ s/%\{(\w+):(\w+)\}/(?<$2>\\S+)/g;

    my $value = $log->{$source} // $log->{meta}{$source} // '';

    if ($value =~ qr/$regex/) {
        my %named = %+;
        $log->{meta} //= {};
        for my $key (keys %named) {
            next unless defined $named{$key};

            # Promote known fields
            if ($key eq 'level') {
                $log->{level} = uc($named{$key});
            } elsif ($key eq 'service') {
                $log->{service} = $named{$key};
            } elsif ($key eq 'host') {
                $log->{host} = $named{$key};
            } elsif ($key eq 'timestamp') {
                $log->{timestamp} = $named{$key};
            } elsif ($key eq 'message' && $source ne 'message') {
                $log->{message} = $named{$key};
            } else {
                $log->{meta}{$key} = $named{$key};
            }
        }
    }

    return $log;
}

1;

__END__

=head1 NAME

Purl::Pipeline::Engine - Log processing pipeline engine

=head1 DESCRIPTION

Processes log entries through ordered rules during ingestion.
Supports regex extraction, JSON parsing, grok patterns, drop
rules, and field mutations.

=cut

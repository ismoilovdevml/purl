package Purl::Pipeline::Engine;
use strict;
use warnings;
use 5.024;

use Moo;
use Time::HiRes ();
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

# ============================================
# Pipeline processing engine
# Applies ordered rules to log entries during
# ingestion for parsing and enrichment.
#
# SECURITY: rule patterns are USER-SUPPLIED and reachable from the
# API (POST /api/pipelines/test, and — imminently — the ingest
# path). Every user regex is therefore run through _safe_regex_match,
# which bounds pattern LENGTH before compiling and bounds EXECUTION
# TIME with a Time::HiRes wall-clock alarm. A catastrophic-
# backtracking pattern aborts instead of pegging the (single-
# threaded) worker. See t/pipeline_redos.t for proof.
# ============================================

has 'pipelines' => (
    is      => 'rw',
    default => sub { [] },
);

# Max wall-clock time a single user regex may run (milliseconds).
# Mirrors Config default pipeline.regex_timeout_ms.
has 'regex_timeout_ms' => (
    is      => 'ro',
    default => sub { 250 },
);

# Max user pattern length accepted before compilation.
# Mirrors Config default pipeline.regex_max_length.
has 'regex_max_length' => (
    is      => 'ro',
    default => sub { 512 },
);

# Apply all enabled pipelines to a log entry
# Returns undef if log should be dropped
sub process {
    my ($self, $log) = @_;
    return $log unless @{ $self->pipelines };

    my $ctx = $self->_regex_ctx;

    for my $pipeline (@{ $self->pipelines }) {
        next unless $pipeline->{enabled};

        # Check if pipeline matches this log (by service filter)
        my $filter_service = $pipeline->{filter_service};
        if (defined $filter_service && length $filter_service) {
            my $res = _safe_regex_match(
                $ctx,
                ($log->{service} // ''),
                $filter_service,
                anchored         => 1,
                case_insensitive => 1,
            );
            # On rejection/timeout OR no match, skip this pipeline.
            next if $res->{error} || !$res->{matched};
        }

        for my $rule (@{ $pipeline->{rules} // [] }) {
            next unless $rule->{enabled} // 1;
            $log = _apply_rule($log, $rule, $ctx);
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

        # Per-sample error collector, surfaced to the API caller.
        my @errors;
        my $ctx = $self->_regex_ctx(\@errors);

        for my $rule (@{ $pipeline->{rules} // [] }) {
            next unless $rule->{enabled} // 1;
            $output = _apply_rule($output, $rule, $ctx);
            last unless defined $output;
        }

        push @results, {
            input   => $input,
            output  => $output,
            dropped => !defined $output,
            (@errors ? (errors => \@errors) : ()),
        };
    }

    return \@results;
}

# Build the regex-guard context threaded through the rule chain.
# $errors (optional) is an arrayref that collects clean error records.
sub _regex_ctx {
    my ($self, $errors) = @_;
    return {
        timeout_ms => $self->regex_timeout_ms,
        max_length => $self->regex_max_length,
        errors     => $errors,
    };
}

# ============================================
# Safe user-regex execution
# ============================================

# Compile and run a user-supplied pattern under length + time bounds.
#
#   _safe_regex_match($ctx, $value, $pattern, %opts)
#     %opts: anchored => bool, case_insensitive => bool
#
# Returns a hashref:
#   { matched => 0|1, named => \%captures }  on success
#   { error   => "message" }                 on reject / bad pattern / timeout
#
# NEVER dies: an invalid or pathological pattern yields a clean error
# instead of crashing the worker.
sub _safe_regex_match {
    my ($ctx, $value, $pattern, %opts) = @_;
    $value   //= '';
    $pattern //= '';

    my $timeout_ms = $ctx->{timeout_ms} || 250;
    my $max_length = $ctx->{max_length} || 512;

    # 1. Length bound — reject absurd patterns before touching the
    #    regex compiler.
    if (length($pattern) > $max_length) {
        return { error => "pattern rejected: exceeds max length ($max_length)" };
    }

    # 2. Compile safely. Invalid syntax => clean error, no crash.
    my $src = $opts{anchored} ? "^$pattern\$" : $pattern;
    my $re  = eval { $opts{case_insensitive} ? qr/$src/i : qr/$src/ };  ## no critic (ProhibitStringyEval)
    if (my $compile_err = $@) {
        return { error => 'invalid pattern: ' . _clean_err($compile_err) };
    }
    return { error => 'invalid pattern' } unless defined $re;

    # 3. Execute under a wall-clock timeout. On this Perl build a
    #    Time::HiRes alarm DOES interrupt catastrophic backtracking
    #    (verified in t/pipeline_redos.t).
    my $timeout_s = $timeout_ms / 1000;
    my ($matched, %named);
    my $ok = eval {
        local $SIG{ALRM} = sub { die "PURL_REGEX_TIMEOUT\n" };  ## no critic (RequireCarping)
        Time::HiRes::alarm($timeout_s);
        if ($value =~ $re) {
            $matched = 1;
            %named   = %+;
        }
        else {
            $matched = 0;
        }
        Time::HiRes::alarm(0);
        1;
    };
    my $run_err = $@;
    Time::HiRes::alarm(0);   # always clear the alarm, even after die

    if (!$ok) {
        if ($run_err =~ /PURL_REGEX_TIMEOUT/) {
            return { error => "pattern timed out after ${timeout_ms}ms" };
        }
        return { error => 'pattern execution error: ' . _clean_err($run_err) };
    }

    return { matched => $matched, named => \%named };
}

# Strip file/line noise from an eval error for a caller-safe message.
sub _clean_err {
    my ($err) = @_;
    $err //= 'unknown error';
    $err =~ s/\s+at\s+\S+\s+line\s+\d+.*//s;
    $err =~ s/\s+$//;
    return $err;
}

# Record a rejected/failed pattern for the API caller (test mode).
sub _record_error {
    my ($ctx, $rule_type, $message) = @_;
    push @{ $ctx->{errors} }, { rule => $rule_type, error => $message }
        if $ctx->{errors};
    return;
}

# ============================================
# Rule application
# ============================================

sub _apply_rule {
    my ($log, $rule, $ctx) = @_;
    my $type = $rule->{type} // '';

    if ($type eq 'regex') {
        return _rule_regex($log, $rule, $ctx);
    } elsif ($type eq 'json_extract') {
        return _rule_json_extract($log, $rule);
    } elsif ($type eq 'drop') {
        return _rule_drop($log, $rule, $ctx);
    } elsif ($type eq 'mutate') {
        return _rule_mutate($log, $rule);
    } elsif ($type eq 'grok') {
        return _rule_grok($log, $rule, $ctx);
    }

    return $log;  # Unknown rule type, pass through
}

# Regex: extract named captures from a field
sub _rule_regex {
    my ($log, $rule, $ctx) = @_;
    my $source  = $rule->{source_field} // 'message';
    my $pattern = $rule->{pattern}      // '';

    return $log unless $pattern;

    my $value = $log->{$source} // $log->{meta}{$source} // '';

    my $res = _safe_regex_match($ctx, $value, $pattern);
    if ($res->{error}) {
        _record_error($ctx, 'regex', $res->{error});
        return $log;  # pass-through on rejection/timeout, never crash
    }

    if ($res->{matched} && %{ $res->{named} }) {
        # Named captures go to meta
        $log->{meta} //= {};
        for my $key (keys %{ $res->{named} }) {
            $log->{meta}{$key} = $res->{named}{$key}
                if defined $res->{named}{$key};
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
    my ($log, $rule, $ctx) = @_;
    my $field   = $rule->{field}   // 'message';
    my $pattern = $rule->{pattern} // '';

    return $log unless $pattern;

    my $value = $log->{$field} // $log->{meta}{$field} // '';

    my $res = _safe_regex_match($ctx, $value, $pattern, case_insensitive => 1);
    if ($res->{error}) {
        _record_error($ctx, 'drop', $res->{error});
        return $log;  # fail-safe: on rejection/timeout, KEEP the log
    }

    return undef if $res->{matched};  # Signal to drop this log

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
    my ($log, $rule, $ctx) = @_;
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

    my $res = _safe_regex_match($ctx, $value, $regex);
    if ($res->{error}) {
        _record_error($ctx, 'grok', $res->{error});
        return $log;  # pass-through on rejection/timeout, never crash
    }

    if ($res->{matched}) {
        my %named = %{ $res->{named} };
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

All user-supplied regular expressions are executed through an
internal guard (C<_safe_regex_match>) that bounds both pattern
length and wall-clock execution time, protecting the single-
threaded worker against ReDoS (catastrophic backtracking).

=cut

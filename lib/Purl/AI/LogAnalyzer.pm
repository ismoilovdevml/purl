package Purl::AI::LogAnalyzer;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(strip_location);
use namespace::clean;
use JSON::XS ();

# ============================================
# AI-powered batch log analysis.
# Analyzes multiple logs and returns:
#   summary, root_causes, services, severity, suggestions
#
# Privacy: only timestamp, level, service, message
# are sent to the AI — raw/meta are excluded.
# ============================================

has 'provider' => (
    is       => 'ro',
    required => 1,
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->allow_nonref },
);

my $SYSTEM_PROMPT = <<'PROMPT';
You are a DevOps and SRE log analysis expert. Analyze the provided log entries and identify patterns, root causes, and actionable insights.

Respond ONLY with a valid JSON object in this exact format:
{
  "summary": "Brief description of what is happening (1-2 sentences)",
  "root_causes": ["Cause 1", "Cause 2"],
  "services": ["service-name-1", "service-name-2"],
  "severity": "low|medium|high|critical",
  "suggestions": ["Action 1", "Action 2", "Action 3"]
}

Severity levels:
- low: informational issues, no immediate action needed
- medium: degraded performance or intermittent errors
- high: significant errors affecting functionality
- critical: service outages or data loss risk

Do not include any text outside the JSON object.
PROMPT

sub analyze_batch {
    my ($self, $logs, $max_context) = @_;

    $max_context //= 20;

    return { error => 'No logs provided' } unless $logs && @$logs;

    # Limit context size
    my @safe_logs = @{$logs}[0 .. ($#$logs < $max_context - 1 ? $#$logs : $max_context - 1)];

    # Build PII-safe log summary (no raw/meta)
    my @log_lines;
    for my $log (@safe_logs) {
        my $ts      = $log->{timestamp} // 'unknown';
        my $level   = $log->{level}     // 'INFO';
        my $service = $log->{service}   // 'unknown';
        my $message = $log->{message}   // '';

        # Truncate long messages
        $message = substr($message, 0, 300) . '...' if length($message) > 300;

        push @log_lines, "[$ts] [$level] [$service] $message";
    }

    my $log_text  = join("\n", @log_lines);
    my $log_count = scalar @safe_logs;
    my $prompt    = "Analyze these $log_count log entries:\n\n$log_text";

    my $raw = eval { $self->provider->generate($prompt, $SYSTEM_PROMPT) };
    if ($@) {
        return { error => "AI analysis failed: " . strip_location($@) };
    }

    return $self->_parse_json_response($raw, {
        summary     => "Analysis of $log_count logs completed.",
        root_causes => [],
        services    => [],
        severity    => 'medium',
        suggestions => [],
    });
}

sub _parse_json_response {
    my ($self, $raw, $fallback) = @_;

    return $fallback unless $raw;

    # Extract JSON from response (handle markdown code blocks)
    my $json_str = $raw;
    if ($json_str =~ /```(?:json)?\s*([\s\S]+?)\s*```/) {
        $json_str = $1;
    }
    # Find first { ... } block
    if ($json_str =~ /(\{[\s\S]+\})/) {
        $json_str = $1;
    }

    my $result = eval { $self->_json->decode($json_str) };
    if ($@ || !ref $result) {
        # Return fallback with raw text as summary
        $fallback->{summary} = $raw if $raw;
        return $fallback;
    }

    # Ensure required fields
    $result->{summary}     //= $fallback->{summary};
    $result->{root_causes} //= [];
    $result->{services}    //= [];
    $result->{severity}    //= 'medium';
    $result->{suggestions} //= [];

    # Validate severity
    my %valid_severity = map { $_ => 1 } qw(low medium high critical);
    $result->{severity} = 'medium' unless $valid_severity{$result->{severity}};

    return $result;
}

1;

__END__

=head1 NAME

Purl::AI::LogAnalyzer - AI-powered batch log analysis

=head1 SYNOPSIS

    use Purl::AI::Factory;
    use Purl::AI::LogAnalyzer;

    my $provider = Purl::AI::Factory->from_config($config);
    my $analyzer = Purl::AI::LogAnalyzer->new(provider => $provider);

    my $result = $analyzer->analyze_batch(\@logs, 20);
    # Returns: { summary, root_causes, services, severity, suggestions }

=head1 PRIVACY

Only timestamp, level, service, and message fields are sent to the AI.
The raw and meta fields (which may contain PII) are excluded.

=cut

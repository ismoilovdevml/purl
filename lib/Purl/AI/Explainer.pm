package Purl::AI::Explainer;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(strip_location);
use namespace::clean;
use JSON::XS ();

# ============================================
# AI-powered single log entry explanation.
# Explains what a log entry means, why it
# happened, and how to fix it.
#
# Privacy: only timestamp, level, service,
# host, message are sent — raw/meta excluded.
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
You are a DevOps expert who explains log entries to engineers. Analyze the provided log entry and explain it clearly.

Respond ONLY with a valid JSON object in this exact format:
{
  "summary": "What happened in plain English (1-2 sentences)",
  "possible_causes": ["Cause 1", "Cause 2", "Cause 3"],
  "suggested_fixes": ["Fix 1", "Fix 2", "Fix 3"],
  "related_topics": ["Topic 1", "Topic 2"]
}

Be specific and actionable. Focus on practical causes and fixes.
Do not include any text outside the JSON object.
PROMPT

sub explain {
    my ($self, $log) = @_;

    return { error => 'No log provided' } unless $log && ref $log eq 'HASH';

    my $ts      = $log->{timestamp} // 'unknown';
    my $level   = $log->{level}     // 'INFO';
    my $service = $log->{service}   // 'unknown';
    my $host    = $log->{host}      // 'unknown';
    my $message = $log->{message}   // '';

    $message = substr($message, 0, 500) . '...' if length($message) > 500;

    my $prompt = <<"LOG";
Explain this log entry:

Timestamp: $ts
Level: $level
Service: $service
Host: $host
Message: $message
LOG

    my $raw = eval { $self->provider->generate($prompt, $SYSTEM_PROMPT) };
    if ($@) {
        return { error => "AI explanation failed: " . strip_location($@) };
    }

    return $self->_parse_json_response($raw, {
        summary          => "Unable to parse AI response.",
        possible_causes  => [],
        suggested_fixes  => [],
        related_topics   => [],
    });
}

sub _parse_json_response {
    my ($self, $raw, $fallback) = @_;

    return $fallback unless $raw;

    my $json_str = $raw;
    if ($json_str =~ /```(?:json)?\s*([\s\S]+?)\s*```/) {
        $json_str = $1;
    }
    if ($json_str =~ /(\{[\s\S]+\})/) {
        $json_str = $1;
    }

    my $result = eval { $self->_json->decode($json_str) };
    if ($@ || !ref $result) {
        $fallback->{summary} = $raw if $raw;
        return $fallback;
    }

    $result->{summary}         //= $fallback->{summary};
    $result->{possible_causes} //= [];
    $result->{suggested_fixes} //= [];
    $result->{related_topics}  //= [];

    return $result;
}

1;

__END__

=head1 NAME

Purl::AI::Explainer - AI-powered log entry explanation

=head1 SYNOPSIS

    use Purl::AI::Factory;
    use Purl::AI::Explainer;

    my $provider  = Purl::AI::Factory->from_config($config);
    my $explainer = Purl::AI::Explainer->new(provider => $provider);

    my $result = $explainer->explain($log_hash);
    # Returns: { summary, possible_causes, suggested_fixes, related_topics }

=head1 PRIVACY

Only timestamp, level, service, host, and message are sent to the AI.
The raw and meta fields are excluded.

=cut

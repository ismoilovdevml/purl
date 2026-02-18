package Purl::AI::QueryGenerator;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();

# ============================================
# AI-powered natural language to SQL query
# generator. Supports OpenAI and Anthropic.
# ============================================

has 'provider' => (
    is      => 'ro',
    default => 'openai',  # 'openai' or 'anthropic'
);

has 'api_key' => (
    is      => 'ro',
    default => '',
);

has 'model' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return $self->provider eq 'anthropic' ? 'claude-sonnet-4-5-20250929' : 'gpt-4o-mini';
    },
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        HTTP::Tiny->new(timeout => 30, agent => 'Purl/1.0');
    },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical->allow_nonref },
);

# Schema context for the AI prompt
my $SCHEMA_CONTEXT = <<'SCHEMA';
You are a SQL query generator for a ClickHouse log aggregation system called Purl.

Table: purl.logs
Columns:
  - id UUID (log entry ID)
  - timestamp DateTime64(3) (log timestamp, millisecond precision)
  - level LowCardinality(String) — values: TRACE, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY
  - service LowCardinality(String) — application/service name
  - host LowCardinality(String) — hostname or pod name
  - message String — log message text
  - meta String — JSON metadata (namespace, pod, container, node, cluster, etc.)
  - trace_id String — distributed trace ID
  - request_id String — request correlation ID
  - span_id String — OpenTelemetry span ID

Important:
- ALWAYS use formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts for timestamp formatting
- For time ranges use: timestamp >= now() - INTERVAL X HOUR/MINUTE/DAY
- For text search use: message LIKE '%search_term%' (case sensitive) or positionCaseInsensitive(message, 'term') > 0
- For meta fields use: JSONExtractString(meta, 'field_name')
- LIMIT results to 500 by default unless specified
- Return only the SQL query, no explanation
SCHEMA

sub generate {
    my ($self, $question) = @_;

    return { error => 'AI API key not configured' } unless $self->api_key;
    return { error => 'Question is required' } unless $question && length($question) > 0;

    # Truncate long questions
    $question = substr($question, 0, 500) if length($question) > 500;

    my $sql;
    eval {
        if ($self->provider eq 'anthropic') {
            $sql = $self->_call_anthropic($question);
        } else {
            $sql = $self->_call_openai($question);
        }
    };

    if ($@) {
        return { error => "AI API call failed: $@" };
    }

    unless ($sql) {
        return { error => 'Failed to generate SQL query' };
    }

    # Clean up the response
    $sql = _clean_sql($sql);

    # Validate the generated SQL
    my $validation = _validate_sql($sql);
    unless ($validation->{valid}) {
        return { error => $validation->{reason}, generated_sql => $sql };
    }

    return { sql => $sql };
}

sub _call_openai {
    my ($self, $question) = @_;

    my $response = $self->_http->post(
        'https://api.openai.com/v1/chat/completions',
        {
            headers => {
                'Content-Type'  => 'application/json',
                'Authorization' => 'Bearer ' . $self->api_key,
            },
            content => $self->_json->encode({
                model    => $self->model,
                messages => [
                    { role => 'system', content => $SCHEMA_CONTEXT },
                    { role => 'user',   content => $question },
                ],
                temperature => 0,
                max_tokens  => 500,
            }),
        }
    );

    unless ($response->{success}) {
        die "OpenAI API error: $response->{status}";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{choices}[0]{message}{content} // '';
}

sub _call_anthropic {
    my ($self, $question) = @_;

    my $response = $self->_http->post(
        'https://api.anthropic.com/v1/messages',
        {
            headers => {
                'Content-Type'      => 'application/json',
                'x-api-key'         => $self->api_key,
                'anthropic-version' => '2023-06-01',
            },
            content => $self->_json->encode({
                model      => $self->model,
                max_tokens => 500,
                system     => $SCHEMA_CONTEXT,
                messages   => [
                    { role => 'user', content => $question },
                ],
            }),
        }
    );

    unless ($response->{success}) {
        die "Anthropic API error: $response->{status}";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{content}[0]{text} // '';
}

sub _clean_sql {
    my ($sql) = @_;

    # Remove markdown code blocks
    $sql =~ s/```sql\s*//gi;
    $sql =~ s/```\s*//g;

    # Trim whitespace
    $sql =~ s/^\s+//;
    $sql =~ s/\s+$//;

    # Remove trailing semicolons
    $sql =~ s/;\s*$//;

    return $sql;
}

sub _validate_sql {
    my ($sql) = @_;

    # Must be a SELECT query
    unless ($sql =~ /^\s*SELECT/i) {
        return { valid => 0, reason => 'Only SELECT queries are allowed' };
    }

    # Block dangerous operations
    for my $forbidden (qw(DROP ALTER INSERT UPDATE DELETE TRUNCATE CREATE GRANT REVOKE)) {
        if ($sql =~ /\b$forbidden\b/i) {
            return { valid => 0, reason => "Forbidden operation: $forbidden" };
        }
    }

    # Must reference the logs table (or system tables for stats)
    unless ($sql =~ /\blogs\b/i || $sql =~ /\bsystem\.\b/i) {
        return { valid => 0, reason => 'Query must reference the logs table' };
    }

    return { valid => 1 };
}

1;

__END__

=head1 NAME

Purl::AI::QueryGenerator - AI-powered natural language to SQL

=head1 DESCRIPTION

Translates natural language questions about logs into ClickHouse SQL
queries using OpenAI or Anthropic APIs.

=cut

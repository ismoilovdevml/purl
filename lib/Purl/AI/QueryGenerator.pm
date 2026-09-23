package Purl::AI::QueryGenerator;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(strip_location);
use namespace::clean;

use Purl::AI::Factory;
use Purl::AI::SearchBarQuery qw(search_bar_query);

# ============================================
# AI-powered natural language to SQL query
# generator. Uses provider abstraction layer.
# Supports: OpenAI, Anthropic, Gemini, Ollama
# ============================================

has 'provider' => (
    is      => 'ro',
    default => 'openai',
);

has 'api_key' => (
    is      => 'ro',
    default => '',
);

has 'model' => (
    is      => 'ro',
    default => '',
);

has 'base_url' => (
    is      => 'ro',
    default => '',
);

has '_provider_obj' => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_provider',
);

sub _build_provider {
    my ($self) = @_;
    my %opts = (api_key => $self->api_key);
    $opts{model}    = $self->model    if $self->model    && $self->model    ne '';
    $opts{base_url} = $self->base_url if $self->base_url && $self->base_url ne '';
    return Purl::AI::Factory->create($self->provider, %opts);
}

# Schema context for SQL generation
my $SCHEMA_CONTEXT = <<'SCHEMA';
You are a SQL query generator for a ClickHouse log aggregation system called Purl.

Table: purl.logs
Columns:
  - id UUID (log entry ID)
  - timestamp DateTime64(3) (log timestamp, millisecond precision)
  - level LowCardinality(String) - values: TRACE, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL, ALERT, EMERGENCY
  - service LowCardinality(String) - application/service name
  - host LowCardinality(String) - hostname or pod name
  - message String - log message text
  - namespace, pod, container LowCardinality(String) - Kubernetes metadata (empty for non-k8s logs)
  - meta String - JSON metadata (node, cluster, deployment, etc.)
  - trace_id String - distributed trace ID
  - request_id String - request correlation ID
  - span_id String - OpenTelemetry span ID

Important:
- ALWAYS use formatDateTime(timestamp, '%Y-%m-%dT%H:%i:%S') || 'Z' as ts for timestamp formatting
- For time ranges use: timestamp >= now() - INTERVAL X HOUR/MINUTE/DAY
- For text search use: message LIKE '%search_term%' (case sensitive) or positionCaseInsensitive(message, 'term') > 0
- For meta fields use: JSONExtractString(meta, 'field_name')
- LIMIT results to 500 by default unless specified

Also express the question's FILTER in the Purl search-bar syntax (KQL):
- field:value terms, combined with AND, OR, NOT and parentheses; whitespace means AND
- fields: level, service, host, namespace, pod, container, trace_id, request_id, span_id, message, raw, meta.<key>
- quote values that contain spaces: message:"connection refused"
- a quoted phrase alone searches the message: "timeout"
- no time range (the search bar has its own time picker), no aggregation,
  grouping, counting or sorting: only which logs match
- write NONE if the question has no filter that this syntax can express

Respond in exactly this format, with no explanation:
SQL:
<the ClickHouse SELECT query>
SEARCH:
<the search-bar query, or NONE>
SCHEMA

sub generate {
    my ($self, $question) = @_;

    return { error => 'AI API key not configured' }
        unless $self->provider eq 'ollama' || $self->api_key;
    return { error => 'Question is required' }
        unless $question && length($question) > 0;

    $question = substr($question, 0, 500) if length($question) > 500;

    my $answer = eval { $self->_provider_obj->generate($question, $SCHEMA_CONTEXT) };
    if ($@) {
        return { error => "AI API call failed: " . strip_location($@) };
    }

    my ($sql, $search) = _split_answer($answer);
    unless ($sql) {
        return { error => 'Failed to generate SQL query' };
    }

    $sql = _clean_sql($sql);

    my $validation = _validate_sql($sql);
    unless ($validation->{valid}) {
        return { error => $validation->{reason}, generated_sql => $sql };
    }

    # Returned only when the search parser accepts it; a bad one is dropped
    # and the SQL answer stands on its own.
    my $query = search_bar_query($search);
    return { sql => $sql, (defined $query ? (query => $query) : ()) };
}

# Split "SQL: ... SEARCH: ..." into its two parts. A model that ignored the
# format and answered with bare SQL still yields the SQL, and no search query.
sub _split_answer {
    my ($answer) = @_;
    return unless defined $answer && $answer =~ /\S/;
    return ($answer, undef) unless $answer =~ /^\s*SQL:/mi;

    my ($sql)    = $answer =~ /^\s*SQL:[ \t]*\n?(.*?)(?=^\s*SEARCH:|\z)/msi;
    my ($search) = $answer =~ /^\s*SEARCH:[ \t]*\n?(.*?)(?=^\s*SQL:|\z)/msi;
    # The search query is one line; anything after it is commentary.
    ($search) = grep { /\S/ } split /\n/, $search // '';
    return ($sql, $search);
}

sub _clean_sql {
    my ($sql) = @_;
    $sql =~ s/```sql\s*//gi;
    $sql =~ s/```\s*//g;
    $sql =~ s/^\s+//;
    $sql =~ s/\s+$//;
    $sql =~ s/;\s*$//;
    return $sql;
}

sub _validate_sql {
    my ($sql) = @_;

    unless ($sql =~ /^\s*SELECT/i) {
        return { valid => 0, reason => 'Only SELECT queries are allowed' };
    }

    for my $forbidden (qw(DROP ALTER INSERT UPDATE DELETE TRUNCATE CREATE GRANT REVOKE)) {
        if ($sql =~ /\b$forbidden\b/i) {
            return { valid => 0, reason => "Forbidden operation: $forbidden" };
        }
    }

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
queries using the configured AI provider (OpenAI, Anthropic, Gemini, Ollama).
The same answer carries the question's filter in search-bar (KQL) syntax;
C<generate> returns it as C<query> only when L<Purl::AI::SearchBarQuery>
accepts it.

=cut

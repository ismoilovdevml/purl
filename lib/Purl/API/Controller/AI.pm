package Purl::API::Controller::AI;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

use Purl::AI::QueryGenerator;

extends 'Purl::API::Controller::Base';

# ============================================
# AI-powered natural language log query
# ============================================

has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

has '_generator' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_generator',
);

sub _build_generator {
    my ($self) = @_;
    my $ai_config = $self->_get_ai_config();
    return Purl::AI::QueryGenerator->new(
        provider => $ai_config->{provider} // 'openai',
        api_key  => $ai_config->{api_key}  // '',
        model    => $ai_config->{model}    // '',
    );
}

sub _get_ai_config {
    my ($self) = @_;
    return {
        provider => $ENV{PURL_AI_PROVIDER} // 'openai',
        api_key  => $ENV{PURL_AI_API_KEY}  // '',
        model    => $ENV{PURL_AI_MODEL}    // '',
    };
}

sub query {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'ai_query');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $question = $body->{question} // $body->{q} // '';
        unless ($question && length($question) >= 3) {
            $self->render_error($c, 'Question must be at least 3 characters', 400);
            return;
        }

        # Rebuild generator if config changed
        my $ai_config = $self->_get_ai_config();
        unless ($ai_config->{api_key}) {
            $self->render_error($c, 'AI API key not configured. Set PURL_AI_API_KEY environment variable.', 400);
            return;
        }
        $self->_generator($self->_build_generator());

        # Generate SQL
        my $result = $self->_generator->generate($question);

        if ($result->{error}) {
            $c->render(json => {
                error => $result->{error},
                ($result->{generated_sql} ? (generated_sql => $result->{generated_sql}) : ()),
            }, status => 400);
            return;
        }

        my $sql = $result->{sql};

        # Optionally execute the query
        my $execute = $body->{execute} // 1;
        my $query_results;

        if ($execute) {
            eval {
                $query_results = $self->storage->_query_json($sql, no_cache => 1);
            };
            if ($@) {
                $c->render(json => {
                    sql   => $sql,
                    error => "Query execution failed: $@",
                });
                return;
            }

            # Limit results
            if ($query_results && @$query_results > 500) {
                splice @$query_results, 500;
            }
        }

        $c->render(json => {
            question => $question,
            sql      => $sql,
            ($query_results ? (
                results => $query_results,
                total   => scalar @$query_results,
            ) : ()),
        });
    });
}

sub suggest {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        $c->render(json => {
            suggestions => [
                'Show me all errors from the last hour',
                'Which services have the most errors today?',
                'Show log volume per minute for the last 30 minutes',
                'Find all logs containing "timeout" from service api-gateway',
                'What are the top 10 error messages this week?',
                'Show me logs from host web-01 with level WARNING or above',
                'Count logs per service for the last 24 hours',
                'Find traces with errors in multiple services',
            ],
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::AI - AI-powered natural language log query

=head1 DESCRIPTION

Translates natural language questions about logs into SQL queries
and optionally executes them.

Endpoints:
    POST /api/ai/query     - Generate and execute AI query
    GET  /api/ai/suggest   - Get query suggestions

=cut

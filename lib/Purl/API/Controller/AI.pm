package Purl::API::Controller::AI;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::Principal qw(principal_via principal_user);
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);
use JSON::PP ();

use Purl::AI::Factory;
use Purl::AI::QueryGenerator;
use Purl::AI::LogAnalyzer;
use Purl::AI::Explainer;

extends 'Purl::API::Controller::Base';

# ============================================
# AI-powered log query, analysis, explanation
# ============================================

has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

# The LLM-backed endpoints spend a paid provider budget, so they are for
# signed-in people only: an ingest API key (or basic-auth client) must not be
# able to reach them. On an open instance (auth disabled) there are no
# accounts to require, so everyone who can reach the dashboard may use AI.
# Renders 403 and returns 0 when refused.
sub _require_session_user {
    my ($self, $c) = @_;
    return 1 if $self->settings && !$self->settings->auth_enabled;
    return 1 if principal_via($c) eq 'session' && defined principal_user($c);
    $self->render_error($c, 'AI requires a signed-in user', 403);
    return 0;
}

sub _get_ai_config {
    my ($self) = @_;
    if ($self->settings) {
        return {
            provider => $self->settings->get('ai', 'provider') // 'openai',
            api_key  => $self->settings->get('ai', 'api_key')  // '',
            model    => $self->settings->get('ai', 'model')    // '',
            base_url => $self->settings->get('ai', 'base_url') // '',
            enabled  => $self->settings->get('ai', 'enabled')  // 1,
        };
    }
    return {
        provider => $ENV{PURL_AI_PROVIDER} // 'openai',
        api_key  => $ENV{PURL_AI_API_KEY}  // '',
        model    => $ENV{PURL_AI_MODEL}    // '',
        base_url => $ENV{PURL_AI_BASE_URL} // '',
        enabled  => 1,
    };
}

sub _build_provider {
    my ($self) = @_;
    my $cfg = $self->_get_ai_config();
    my %opts = (api_key => $cfg->{api_key});
    $opts{model}    = $cfg->{model}    if $cfg->{model}    && $cfg->{model}    ne '';
    $opts{base_url} = $cfg->{base_url} if $cfg->{base_url} && $cfg->{base_url} ne '';
    return eval { Purl::AI::Factory->create($cfg->{provider}, %opts) };
}

sub _ai_configured {
    my ($self) = @_;
    my $cfg = $self->_get_ai_config();
    return 0 unless $cfg->{enabled} // 1;
    return 1 if $cfg->{provider} eq 'ollama';
    return $cfg->{api_key} && $cfg->{api_key} ne '';
}

# ============================================
# POST /api/ai/query — NL to SQL
# ============================================

sub query {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->_require_session_user($c);

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

        unless ($self->_ai_configured()) {
            $self->render_error($c, 'AI not configured. Go to Settings > AI to configure a provider.', 400);
            return;
        }

        my $cfg      = $self->_get_ai_config();
        my %opts     = (api_key => $cfg->{api_key});
        $opts{model}    = $cfg->{model}    if $cfg->{model}    && $cfg->{model}    ne '';
        $opts{base_url} = $cfg->{base_url} if $cfg->{base_url} && $cfg->{base_url} ne '';

        my $generator = Purl::AI::QueryGenerator->new(provider => $cfg->{provider}, %opts);
        my $result    = $generator->generate($question);

        if ($result->{error}) {
            $c->render(json => {
                error => $result->{error},
                ($result->{generated_sql} ? (generated_sql => $result->{generated_sql}) : ()),
            }, status => 400);
            return;
        }

        my $sql          = $result->{sql};
        my $execute      = $body->{execute} // 1;
        my $query_results;

        if ($execute) {
            eval {
                $query_results = $self->storage->_query_json($sql, no_cache => 1);
            };
            if ($@) {
                $c->render(json => { sql => $sql, error => "Query execution failed: $@" });
                return;
            }
            splice @$query_results, 500 if $query_results && @$query_results > 500;
        }

        $c->render(json => {
            question => $question,
            sql      => $sql,
            provider => $cfg->{provider},
            ($query_results ? (results => $query_results, total => scalar @$query_results) : ()),
        });
    });
}

# ============================================
# GET /api/ai/suggest — Query suggestions
# ============================================

sub suggest {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my @suggestions = (
            'Show me all errors from the last hour',
            'Which services have the most errors today?',
            'Show log volume per minute for the last 30 minutes',
            'Find all logs containing "timeout" in the last 24 hours',
            'What are the top 10 error messages this week?',
            'Show me ERROR and CRITICAL logs from the last 15 minutes',
            'Count logs per service for the last 24 hours',
            'Find traces with errors in multiple services',
        );

        eval {
            my $services = $self->storage->_query_json(
                "SELECT service, count() as cnt FROM purl.logs WHERE timestamp >= now() - INTERVAL 1 DAY GROUP BY service ORDER BY cnt DESC LIMIT 3",
                no_cache => 0,
            );
            if ($services && @$services) {
                for my $svc (@$services) {
                    my $name = $svc->{service} // '';
                    next unless $name && $name ne 'unknown';
                    unshift @suggestions, "Show all ERROR logs from service $name";
                }
                splice @suggestions, 8;
            }
        };

        $c->render(json => { suggestions => \@suggestions });
    });
}

# ============================================
# POST /api/ai/analyze — Batch log analysis
# ============================================

sub analyze {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->_require_session_user($c);

        unless ($self->_ai_configured()) {
            $self->render_error($c, 'AI not configured. Go to Settings > AI to configure a provider.', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $logs    = $body->{logs}    // [];
        my $log_ids = $body->{log_ids} // [];

        if (@$log_ids && !@$logs) {
            eval {
                my @safe_ids = grep { /^[a-f0-9\-]+$/i } @{$log_ids}[0..($#$log_ids < 49 ? $#$log_ids : 49)];
                if (@safe_ids) {
                    my $ids_str = join(',', map { "'$_'" } @safe_ids);
                    $logs = $self->storage->_query_json(
                        "SELECT timestamp, level, service, host, message FROM purl.logs WHERE id IN ($ids_str) LIMIT 50",
                        no_cache => 1,
                    );
                }
            };
        }

        unless ($logs && @$logs) {
            $self->render_error($c, 'No logs provided for analysis', 400);
            return;
        }

        my $max_context = $self->settings
            ? ($self->settings->get('ai', 'max_log_context') // 20)
            : 20;

        my $provider = $self->_build_provider();
        unless ($provider) {
            $self->render_error($c, 'Failed to initialize AI provider', 500);
            return;
        }

        my $analyzer     = Purl::AI::LogAnalyzer->new(provider => $provider);
        my $result       = $analyzer->analyze_batch($logs, $max_context);

        if ($result->{error}) {
            $c->render(json => { error => $result->{error} }, status => 500);
            return;
        }

        my $analyzed = @$logs > $max_context ? $max_context : scalar @$logs;
        $c->render(json => { %$result, analyzed_count => $analyzed });
    });
}

# ============================================
# POST /api/ai/explain — Single log explanation
# ============================================

sub explain {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->_require_session_user($c);

        unless ($self->_ai_configured()) {
            $self->render_error($c, 'AI not configured. Go to Settings > AI to configure a provider.', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $log = $body->{log};

        if (!$log && $body->{log_id}) {
            eval {
                my $id = $body->{log_id};
                $id =~ s/[^a-f0-9\-]//gi;
                my $rows = $self->storage->_query_json(
                    "SELECT timestamp, level, service, host, message FROM purl.logs WHERE id = '$id' LIMIT 1",
                    no_cache => 1,
                );
                $log = $rows->[0] if $rows && @$rows;
            };
        }

        unless ($log && ref $log eq 'HASH') {
            $self->render_error($c, 'No log provided for explanation', 400);
            return;
        }

        my $provider  = $self->_build_provider();
        unless ($provider) {
            $self->render_error($c, 'Failed to initialize AI provider', 500);
            return;
        }

        my $explainer = Purl::AI::Explainer->new(provider => $provider);
        my $result    = $explainer->explain($log);

        if ($result->{error}) {
            $c->render(json => { error => $result->{error} }, status => 500);
            return;
        }

        $c->render(json => $result);
    });
}

# ============================================
# GET /api/ai/providers — List available
# ============================================

sub providers {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $cfg        = $self->_get_ai_config();
        my $configured = $self->_ai_configured();

        $c->render(json => {
            current    => $cfg->{provider},
            configured => $configured ? JSON::PP::true() : JSON::PP::false(),
            providers  => Purl::AI::Factory->available_providers(),
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::AI - AI-powered log analysis controller

=head1 DESCRIPTION

Endpoints:
    POST /api/ai/query     - NL to SQL (requires: ai_query feature)
    GET  /api/ai/suggest   - Query suggestions
    POST /api/ai/analyze   - Batch log analysis (requires: ai_analysis feature)
    POST /api/ai/explain   - Single log explanation (requires: ai_analysis feature)
    GET  /api/ai/providers - List available AI providers

=cut

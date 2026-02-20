package Purl::AI::Provider::Ollama;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

with 'Purl::AI::Provider::Base';

# ============================================
# Ollama self-hosted provider (local LLMs)
# Supports: llama3.2, mistral, deepseek, etc.
# ============================================

sub default_model { 'llama3.2' }

# Override base_url default for Ollama
around 'base_url' => sub {
    my ($orig, $self) = @_;
    my $url = $self->$orig();
    return $url && $url ne '' ? $url : 'http://localhost:11434';
};

sub call_api {
    my ($self, $prompt, $system_prompt) = @_;

    # Build combined prompt if system prompt provided
    my $full_prompt = $system_prompt
        ? "$system_prompt\n\n$prompt"
        : $prompt;

    my $url = $self->base_url . '/api/generate';

    my $response = $self->_http->post(
        $url,
        {
            headers => { 'Content-Type' => 'application/json' },
            content => $self->_json->encode({
                model  => $self->model,
                prompt => $full_prompt,
                stream => JSON::XS::false(),
            }),
        }
    );

    unless ($response->{success}) {
        my $err = eval { $self->_json->decode($response->{content})->{error} } // $response->{status};
        die "Ollama API error: $err\n";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{response} // '';
}

1;

__END__

=head1 NAME

Purl::AI::Provider::Ollama - Ollama self-hosted LLM provider

=head1 DESCRIPTION

Implements Purl::AI::Provider::Base for Ollama local API.
Default model: llama3.2
Default base_url: http://localhost:11434

No API key required — runs locally.

=cut

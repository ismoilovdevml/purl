package Purl::AI::Provider::OpenAI;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

with 'Purl::AI::Provider::Base';

# ============================================
# OpenAI provider (GPT-4o, GPT-4o-mini, etc.)
# ============================================

sub default_model { 'gpt-4o-mini' }

sub call_api {
    my ($self, $prompt, $system_prompt) = @_;

    die "OpenAI API key is required\n" unless $self->api_key;

    my @messages;
    push @messages, { role => 'system', content => $system_prompt } if $system_prompt;
    push @messages, { role => 'user',   content => $prompt };

    my $response = $self->_http->post(
        'https://api.openai.com/v1/chat/completions',
        {
            headers => {
                'Content-Type'  => 'application/json',
                'Authorization' => 'Bearer ' . $self->api_key,
            },
            content => $self->_json->encode({
                model       => $self->model,
                messages    => \@messages,
                temperature => 0,
                max_tokens  => 1000,
            }),
        }
    );

    unless ($response->{success}) {
        my $err = eval { $self->_json->decode($response->{content})->{error}{message} } // $response->{status};
        die "OpenAI API error: $err\n";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{choices}[0]{message}{content} // '';
}

1;

__END__

=head1 NAME

Purl::AI::Provider::OpenAI - OpenAI GPT provider

=head1 DESCRIPTION

Implements Purl::AI::Provider::Base for OpenAI API.
Default model: gpt-4o-mini

=cut

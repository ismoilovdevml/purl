package Purl::AI::Provider::Gemini;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

with 'Purl::AI::Provider::Base';

# ============================================
# Google Gemini provider
# ============================================

sub default_model { 'gemini-2.0-flash' }

sub call_api {
    my ($self, $prompt, $system_prompt) = @_;

    die "Gemini API key is required\n" unless $self->api_key;

    my $model = $self->model;
    my $url   = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=" . $self->api_key;

    my %payload = (
        contents => [
            {
                parts => [ { text => $prompt } ],
            },
        ],
        generationConfig => {
            temperature    => 0,
            maxOutputTokens => 1000,
        },
    );

    if ($system_prompt) {
        $payload{systemInstruction} = {
            parts => [ { text => $system_prompt } ],
        };
    }

    my $response = $self->_http->post(
        $url,
        {
            headers => { 'Content-Type' => 'application/json' },
            content => $self->_json->encode(\%payload),
        }
    );

    unless ($response->{success}) {
        my $err = eval { $self->_json->decode($response->{content})->{error}{message} } // $response->{status};
        die "Gemini API error: $err\n";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{candidates}[0]{content}{parts}[0]{text} // '';
}

1;

__END__

=head1 NAME

Purl::AI::Provider::Gemini - Google Gemini provider

=head1 DESCRIPTION

Implements Purl::AI::Provider::Base for Google Gemini API.
Default model: gemini-2.0-flash

=cut

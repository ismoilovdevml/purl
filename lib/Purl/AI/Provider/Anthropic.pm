package Purl::AI::Provider::Anthropic;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

with 'Purl::AI::Provider::Base';

# ============================================
# Anthropic Claude provider
# ============================================

sub default_model { 'claude-haiku-4-5-20251001' }

sub call_api {
    my ($self, $prompt, $system_prompt) = @_;

    die "Anthropic API key is required\n" unless $self->api_key;

    my %payload = (
        model      => $self->model,
        max_tokens => 1000,
        messages   => [
            { role => 'user', content => $prompt },
        ],
    );
    $payload{system} = $system_prompt if $system_prompt;

    my $response = $self->_http->post(
        'https://api.anthropic.com/v1/messages',
        {
            headers => {
                'Content-Type'      => 'application/json',
                'x-api-key'         => $self->api_key,
                'anthropic-version' => '2023-06-01',
            },
            content => $self->_json->encode(\%payload),
        }
    );

    unless ($response->{success}) {
        my $err = eval { $self->_json->decode($response->{content})->{error}{message} } // $response->{status};
        die "Anthropic API error: $err\n";
    }

    my $data = $self->_json->decode($response->{content});
    return $data->{content}[0]{text} // '';
}

1;

__END__

=head1 NAME

Purl::AI::Provider::Anthropic - Anthropic Claude provider

=head1 DESCRIPTION

Implements Purl::AI::Provider::Base for Anthropic API.
Default model: claude-haiku-4-5-20251001

=cut

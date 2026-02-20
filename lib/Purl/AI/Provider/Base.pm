package Purl::AI::Provider::Base;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;
use HTTP::Tiny;
use JSON::XS ();

# ============================================
# Base role for all AI providers.
# Implementors must provide: call_api, default_model
# ============================================

requires 'call_api';       # ($self, $prompt, $system_prompt) → $text
requires 'default_model';  # ($self) → string

has 'api_key' => (
    is      => 'ro',
    default => '',
);

has 'model' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return $self->default_model();
    },
);

has 'base_url' => (
    is      => 'ro',
    default => '',
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        HTTP::Tiny->new(
            timeout => 30,
            agent   => 'Purl/1.0',
        );
    },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8->canonical->allow_nonref },
);

# Generate text from a prompt with optional system context.
# Returns plain text string or dies on error.
sub generate {
    my ($self, $prompt, $system_prompt) = @_;

    $system_prompt //= '';

    my $text = eval { $self->call_api($prompt, $system_prompt) };
    if ($@) {
        die $@;
    }

    return $text // '';
}

1;

__END__

=head1 NAME

Purl::AI::Provider::Base - Moo role for AI provider implementations

=head1 SYNOPSIS

    package Purl::AI::Provider::MyProvider;
    use Moo;
    with 'Purl::AI::Provider::Base';

    sub default_model { 'my-model-v1' }

    sub call_api {
        my ($self, $prompt, $system) = @_;
        # ... call your API ...
        return $text;
    }

=head1 REQUIRED METHODS

=over 4

=item B<call_api>($prompt, $system_prompt) → $text

Make the actual API call and return generated text.

=item B<default_model>() → $model_name

Return the default model name for this provider.

=back

=cut

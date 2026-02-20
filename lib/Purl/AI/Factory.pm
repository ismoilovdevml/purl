package Purl::AI::Factory;
use strict;
use warnings;
use 5.024;

use namespace::clean;

use Purl::AI::Provider::OpenAI;
use Purl::AI::Provider::Anthropic;
use Purl::AI::Provider::Gemini;
use Purl::AI::Provider::Ollama;

# ============================================
# Factory for creating AI provider instances.
# Usage:
#   my $provider = Purl::AI::Factory->create('openai', api_key => '...');
#   my $provider = Purl::AI::Factory->from_config($config);
# ============================================

my %PROVIDERS = (
    openai    => 'Purl::AI::Provider::OpenAI',
    anthropic => 'Purl::AI::Provider::Anthropic',
    gemini    => 'Purl::AI::Provider::Gemini',
    ollama    => 'Purl::AI::Provider::Ollama',
);

sub create {
    my ($class, $provider_name, %opts) = @_;

    $provider_name = lc($provider_name // 'openai');

    my $pkg = $PROVIDERS{$provider_name}
        or die "Unknown AI provider: '$provider_name'. Supported: " . join(', ', sort keys %PROVIDERS) . "\n";

    return $pkg->new(%opts);
}

sub from_config {
    my ($class, $config) = @_;

    my $provider = $config->get('ai', 'provider') // 'openai';
    my $api_key  = $config->get('ai', 'api_key')  // '';
    my $model    = $config->get('ai', 'model')     // '';
    my $base_url = $config->get('ai', 'base_url')  // '';

    my %opts = (api_key => $api_key);
    $opts{model}    = $model    if $model    && $model    ne '';
    $opts{base_url} = $base_url if $base_url && $base_url ne '';

    return $class->create($provider, %opts);
}

sub available_providers {
    return [
        {
            id           => 'openai',
            name         => 'OpenAI',
            default_model => 'gpt-4o-mini',
            models       => ['gpt-4o-mini', 'gpt-4o', 'gpt-4-turbo'],
            requires_key => 1,
            requires_url => 0,
        },
        {
            id           => 'anthropic',
            name         => 'Anthropic',
            default_model => 'claude-haiku-4-5-20251001',
            models       => ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6', 'claude-opus-4-6'],
            requires_key => 1,
            requires_url => 0,
        },
        {
            id           => 'gemini',
            name         => 'Google Gemini',
            default_model => 'gemini-2.0-flash',
            models       => ['gemini-2.0-flash', 'gemini-1.5-pro', 'gemini-1.5-flash'],
            requires_key => 1,
            requires_url => 0,
        },
        {
            id           => 'ollama',
            name         => 'Ollama (Self-hosted)',
            default_model => 'llama3.2',
            models       => ['llama3.2', 'llama3.1', 'mistral', 'deepseek-r1', 'qwen2.5'],
            requires_key => 0,
            requires_url => 1,
        },
    ];
}

1;

__END__

=head1 NAME

Purl::AI::Factory - Factory for AI provider instantiation

=head1 SYNOPSIS

    use Purl::AI::Factory;

    # Create by name
    my $provider = Purl::AI::Factory->create('openai', api_key => 'sk-...');
    my $text = $provider->generate('Hello', 'You are a helpful assistant');

    # Create from Config object
    my $provider = Purl::AI::Factory->from_config($config);

    # List available providers
    my $list = Purl::AI::Factory->available_providers();

=cut

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Purl::AI::Factory;

# ============================================
# Model version constants (2026 expected values)
# ============================================

my %EXPECTED_DEFAULTS = (
    openai    => 'gpt-4.1-mini-2025-04-14',
    anthropic => 'claude-haiku-4-5-20251001',
    gemini    => 'gemini-2.5-flash',
    ollama    => 'llama3.3',
);

# Models that must NOT appear (deprecated/retired)
my %FORBIDDEN_MODELS = (
    openai    => [qw(gpt-4o-mini gpt-4-turbo gpt-3.5-turbo)],
    anthropic => [qw(claude-3-haiku-20240307 claude-3-sonnet-20240229 claude-2)],
    gemini    => [qw(gemini-2.0-flash gemini-2.0-flash-001 gemini-1.5-pro gemini-1.5-flash)],
    ollama    => [qw(llama3.2 llama3.1 llama2)],
);

# ============================================
# Factory: available_providers() structure
# ============================================

subtest 'available_providers returns all 4 providers' => sub {
    my $providers = Purl::AI::Factory->available_providers();
    is ref $providers, 'ARRAY', 'returns arrayref';
    is scalar @$providers, 4, '4 providers defined';

    my %by_id = map { $_->{id} => $_ } @$providers;
    ok exists $by_id{openai},    'openai present';
    ok exists $by_id{anthropic}, 'anthropic present';
    ok exists $by_id{gemini},    'gemini present';
    ok exists $by_id{ollama},    'ollama present';
};

subtest 'provider default models are current 2026 versions' => sub {
    my $providers = Purl::AI::Factory->available_providers();
    my %by_id = map { $_->{id} => $_ } @$providers;

    while (my ($id, $expected) = each %EXPECTED_DEFAULTS) {
        is $by_id{$id}{default_model}, $expected,
            "$id default_model is '$expected'";
    }
};

subtest 'providers do not contain deprecated model IDs' => sub {
    my $providers = Purl::AI::Factory->available_providers();
    my %by_id = map { $_->{id} => $_ } @$providers;

    while (my ($provider_id, $forbidden) = each %FORBIDDEN_MODELS) {
        my $models = $by_id{$provider_id}{models} // [];
        for my $bad_model (@$forbidden) {
            ok !grep { $_ eq $bad_model } @$models,
                "$provider_id: '$bad_model' (deprecated) not in models list";
        }
    }
};

subtest 'gemini does not use 2.0 series (retiring March 2026)' => sub {
    my $providers = Purl::AI::Factory->available_providers();
    my ($gemini) = grep { $_->{id} eq 'gemini' } @$providers;

    unlike $gemini->{default_model}, qr/gemini-2\.0/,
        'Gemini default model is not 2.0 series';

    for my $m (@{$gemini->{models}}) {
        unlike $m, qr/gemini-2\.0/, "Gemini model '$m' is not 2.0 series";
        unlike $m, qr/gemini-1\.5/, "Gemini model '$m' is not 1.5 series";
    }
};

# ============================================
# Provider instances: default_model()
# ============================================

subtest 'OpenAI provider default_model is gpt-4.1-mini' => sub {
    require Purl::AI::Provider::OpenAI;
    my $p = Purl::AI::Provider::OpenAI->new(api_key => 'test-key');
    is $p->default_model, 'gpt-4.1-mini-2025-04-14', 'OpenAI default_model correct';
    is $p->model,         'gpt-4.1-mini-2025-04-14', 'OpenAI model attribute correct';
};

subtest 'Anthropic provider default_model is claude-haiku-4-5' => sub {
    require Purl::AI::Provider::Anthropic;
    my $p = Purl::AI::Provider::Anthropic->new(api_key => 'test-key');
    is $p->default_model, 'claude-haiku-4-5-20251001', 'Anthropic default_model correct';
    is $p->model,         'claude-haiku-4-5-20251001', 'Anthropic model attribute correct';
    unlike $p->default_model, qr/claude-3/, 'No Claude 3 in default (deprecated)';
};

subtest 'Gemini provider default_model is gemini-2.5-flash' => sub {
    require Purl::AI::Provider::Gemini;
    my $p = Purl::AI::Provider::Gemini->new(api_key => 'test-key');
    is $p->default_model, 'gemini-2.5-flash', 'Gemini default_model correct';
    unlike $p->default_model, qr/2\.0/, 'Gemini 2.0 not used (retiring March 2026)';
    unlike $p->default_model, qr/1\.5/, 'Gemini 1.5 not used';
};

subtest 'Ollama provider default_model is llama3.3' => sub {
    require Purl::AI::Provider::Ollama;
    my $p = Purl::AI::Provider::Ollama->new();
    is $p->default_model, 'llama3.3', 'Ollama default_model correct';
    unlike $p->default_model, qr/llama3\.2/, 'llama3.2 not used (outdated)';
    is $p->base_url, 'http://localhost:11434', 'Ollama default base_url correct';
};

# ============================================
# Factory: create() with custom model override
# ============================================

subtest 'Factory creates provider with custom model' => sub {
    my $p = Purl::AI::Factory->create('openai',
        api_key => 'sk-test',
        model   => 'gpt-5-2025-08-07',
    );
    isa_ok $p, 'Purl::AI::Provider::OpenAI';
    is $p->model, 'gpt-5-2025-08-07', 'custom model applied';
};

subtest 'Factory rejects unknown provider' => sub {
    eval { Purl::AI::Factory->create('unknown-provider', api_key => 'x') };
    like $@, qr/Unknown AI provider/, 'dies with unknown provider message';
};

subtest 'Factory creates Ollama without api_key' => sub {
    my $p = eval { Purl::AI::Factory->create('ollama') };
    ok !$@, 'Ollama created without error';
    isa_ok $p, 'Purl::AI::Provider::Ollama';
};

done_testing;

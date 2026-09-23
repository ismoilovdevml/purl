package Purl::API::Controller::Settings::AI;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Settings manager (Purl::Config instance)
has 'settings' => (
    is       => 'ro',
    required => 1,
);

# ============================================
# AI Settings
# ============================================

sub get_ai {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $ai = $self->settings->get_section('ai') // {};

        # Mask API key
        my $safe = { %$ai };
        $safe->{api_key} = $safe->{api_key} ? '********' : '';

        $c->render(json => {
            config   => $safe,
            from_env => $self->env_flags('ai'),
        });
    });
}

sub update_ai {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Silently skipping ENV-owned keys and answering 200 is the twin-site
        # bug from #53: the caller is told the value changed and it did not.
        # Guard before validation — see Settings::LDAP::update_ldap.
        # '********' is get_ai's mask for api_key and means "unchanged".
        return if $self->reject_env_managed($c, 'ai', $body,
            unchanged_marker => '********');

        my %allowed_providers = map { $_ => 1 } qw(openai anthropic gemini ollama);
        if (exists $body->{provider} && !$allowed_providers{$body->{provider}}) {
            $self->render_error($c, "Invalid provider. Allowed: openai, anthropic, gemini, ollama", 400);
            return;
        }

        my $current = $self->settings->get_section('ai') // {};

        for my $key (qw(provider model base_url enabled max_log_context cache_ttl)) {
            next unless exists $body->{$key};
            $current->{$key} = $body->{$key};
        }

        # Only update api_key if not masked
        if (exists $body->{api_key} && $body->{api_key} ne '********') {
            $current->{api_key} = $body->{api_key};
        }

        if ($self->settings->set_section('ai', $current)) {
            $c->audit_event(action => 'update_settings', resource_type => 'settings', resource_id => 'ai');
            $c->render(json => { status => 'ok', message => 'AI settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save AI settings', 500);
        }
    });
}

sub test_ai {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        require Purl::AI::Factory;

        my $provider_name = $self->settings->get('ai', 'provider') // 'openai';
        my $api_key       = $self->settings->get('ai', 'api_key')  // '';
        my $model         = $self->settings->get('ai', 'model')    // '';
        my $base_url      = $self->settings->get('ai', 'base_url') // '';

        unless ($provider_name eq 'ollama' || ($api_key && $api_key ne '')) {
            $c->render(json => {
                status  => 'error',
                message => 'API key is required for this provider.',
            });
            return;
        }

        my %opts = (api_key => $api_key);
        $opts{model}    = $model    if $model    && $model    ne '';
        $opts{base_url} = $base_url if $base_url && $base_url ne '';

        my $provider = eval { Purl::AI::Factory->create($provider_name, %opts) };
        if ($@) {
            $c->render(json => { status => 'error', message => "Provider init failed: $@" });
            return;
        }

        my $response = eval { $provider->generate('Reply with: OK', 'You are a test assistant. Reply with just: OK') };
        if ($@) {
            $c->render(json => { status => 'error', message => "Connection failed: $@" });
            return;
        }

        $c->render(json => {
            status   => 'ok',
            provider => $provider_name,
            model    => $provider->model,
            message  => 'AI provider connected successfully.',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::AI - AI provider settings and connection test

=cut

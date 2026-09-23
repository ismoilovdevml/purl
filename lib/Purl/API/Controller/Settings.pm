package Purl::API::Controller::Settings;
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

# Callback to rebuild storage after settings change
has 'rebuild_storage' => (
    is      => 'ro',
    default => sub { sub {} },
);

sub get_all {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $all = $self->settings->get_all();

        my $result = {
            clickhouse => {
                host     => { value => $all->{clickhouse}{host}, from_env => $self->settings->is_from_env('clickhouse', 'host') },
                port     => { value => $all->{clickhouse}{port}, from_env => $self->settings->is_from_env('clickhouse', 'port') },
                database => { value => $all->{clickhouse}{database}, from_env => $self->settings->is_from_env('clickhouse', 'database') },
                user     => { value => $all->{clickhouse}{user}, from_env => $self->settings->is_from_env('clickhouse', 'user') },
                password_set => { value => ($all->{clickhouse}{password} ? 1 : 0), from_env => $self->settings->is_from_env('clickhouse', 'password') },
            },
            retention => {
                days => { value => $all->{retention}{days}, from_env => $self->settings->is_from_env('retention', 'days') },
            },
            auth => {
                enabled => { value => $all->{auth}{enabled}, from_env => $self->settings->is_from_env('auth', 'enabled') },
            },
            notifications => {
                telegram => {
                    enabled   => $self->settings->get_nested('notifications', 'telegram', 'enabled') // 0,
                    bot_token => $self->settings->get_nested('notifications', 'telegram', 'bot_token') ? 1 : 0,
                    chat_id   => $self->settings->get_nested('notifications', 'telegram', 'chat_id') ? 1 : 0,
                    # The VALUE, not an is-set flag: a forum topic id is routing
                    # config, not a secret (so it is deliberately not in
                    # %WRITE_ONLY). Without it the panel rendered the input
                    # empty and the next save posted thread_id: "" over the
                    # stored topic — #68's silent rewrite, on a field that was
                    # not read by anything either (#71).
                    thread_id => $self->settings->get_nested('notifications', 'telegram', 'thread_id') // '',
                    from_env  => $ENV{PURL_TELEGRAM_BOT_TOKEN} ? 1 : 0,
                },
                slack => {
                    enabled     => $self->settings->get_nested('notifications', 'slack', 'enabled') // 0,
                    webhook_set => $self->settings->get_nested('notifications', 'slack', 'webhook_url') ? 1 : 0,
                    channel     => $self->settings->get_nested('notifications', 'slack', 'channel') // '',
                    from_env    => $ENV{PURL_SLACK_WEBHOOK_URL} ? 1 : 0,
                },
                webhook => {
                    enabled  => $self->settings->get_nested('notifications', 'webhook', 'enabled') // 0,
                    url_set  => $self->settings->get_nested('notifications', 'webhook', 'url') ? 1 : 0,
                    # auth_token is write-only like the rest, but it was the one
                    # such key with no is-set flag — so the UI could not tell
                    # "no token" from "token it may not see", and could not
                    # honestly offer to remove it even though the endpoint
                    # accepts clear_auth_token.
                    auth_token_set => $self->settings->get_nested('notifications', 'webhook', 'auth_token') ? 1 : 0,
                    from_env => $ENV{PURL_ALERT_WEBHOOK_URL} ? 1 : 0,
                },
                # Per-key truth, keyed by the dotted name (telegram.chat_id,
                # slack.channel, webhook.auth_token, ...). The three scalar
                # flags above only track each channel's bot_token/webhook_url,
                # so a chat_id or channel pinned by its own env var rendered as
                # editable. Additive: the existing flags are untouched.
                from_env_keys => $self->env_flags('notifications'),
            },
        };

        $c->render(json => $result);
    });
}

sub update_clickhouse {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Before the ENV guard, because it strips the clear_* fields off $body:
        # they are instructions, not proposed values, and must not be weighed as
        # edits or written to settings.json as config keys.
        my $clear = $self->take_clear_requests($c, 'clickhouse', $body) or return;

        return if $self->reject_env_managed($c, 'clickhouse', $body);

        # Erase first, then save. With the stored value already gone,
        # _writable_values has nothing to restore for the blank password field
        # and drops it — so the ordinary write path needs no special case.
        $self->settings->clear_secrets('clickhouse', @$clear);

        # Update settings
        my $current = $self->settings->get_section('clickhouse');
        for my $key (qw(host port database user password)) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        if ($self->settings->set_section('clickhouse', $current)) {
            # Rebuild storage with new settings
            $self->rebuild_storage->();
            $c->audit_event(action => 'update_settings', resource_type => 'settings',
                resource_id => 'clickhouse');

            $c->render(json => {
                status  => 'ok',
                message => 'ClickHouse settings updated. Restart may be required for full effect.',
                cleared => $clear,
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub update_retention {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $self->render_error($c, 'days required', 400);
            return;
        }

        return if $self->reject_env_managed($c, 'retention', { days => $body->{days} });

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $self->render_error($c, 'days must be between 1 and 365', 400);
            return;
        }

        if ($self->settings->set('retention', 'days', $days)) {
            # Update ClickHouse TTL
            eval { $self->storage->update_retention($days) };
            if ($@) {
                $c->app->log->warn("Failed to update ClickHouse retention TTL: $@");
            }
            $c->audit_event(action => 'update_settings', resource_type => 'settings',
                resource_id => 'retention', details => "days=$days");

            $c->render(json => {
                status         => 'ok',
                retention_days => $days,
                message        => "Retention updated to $days days.",
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings - settings overview, ClickHouse connection and retention

The other settings sections have their own controllers under
C<Purl::API::Controller::Settings::*> (Notifications, ApiKeys, Users, LDAP,
SSO, AI, Redis).

=cut

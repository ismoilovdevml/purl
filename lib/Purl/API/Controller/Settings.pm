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

# Notifiers hash reference for test notifications
has 'notifiers' => (
    is      => 'ro',
    default => sub { {} },
);

# Callback to rebuild notifiers after settings change
has 'rebuild_notifiers' => (
    is      => 'ro',
    default => sub { sub {} },
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
                    from_env => $ENV{PURL_ALERT_WEBHOOK_URL} ? 1 : 0,
                },
            },
        };

        $c->render(json => $result);
    });
}

sub update_clickhouse {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Check which fields are from ENV (cannot modify)
        my @from_env;
        for my $key (qw(host port database user password)) {
            if ($self->settings->is_from_env('clickhouse', $key) && exists $body->{$key}) {
                push @from_env, $key;
            }
        }

        if (@from_env) {
            $c->render(json => {
                error    => "Cannot modify ENV-configured values: " . join(', ', @from_env),
                from_env => \@from_env,
            }, status => 400);
            return;
        }

        # Update settings
        my $current = $self->settings->get_section('clickhouse');
        for my $key (qw(host port database user password)) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        if ($self->settings->set_section('clickhouse', $current)) {
            # Rebuild storage with new settings
            $self->rebuild_storage->();

            $c->render(json => {
                status  => 'ok',
                message => 'ClickHouse settings updated. Restart may be required for full effect.',
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub update_notifications {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type');
        my $body = eval { decode_json($c->req->body) };

        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $self->render_error($c, 'Invalid notification type', 400);
            return;
        }

        # Check ENV override
        my %env_check = (
            telegram => 'PURL_TELEGRAM_BOT_TOKEN',
            slack    => 'PURL_SLACK_WEBHOOK_URL',
            webhook  => 'PURL_ALERT_WEBHOOK_URL',
        );

        if ($ENV{$env_check{$type}}) {
            $c->render(json => {
                error    => "Cannot modify - configured via environment variable",
                from_env => 1,
            }, status => 400);
            return;
        }

        # Get current notifications config
        my $notifications = $self->settings->_config->{notifications} // {};
        $notifications->{$type} = $body;

        if ($self->settings->set_section('notifications', $notifications)) {
            # Rebuild notifiers
            $self->rebuild_notifiers->();

            $c->render(json => {
                status  => 'ok',
                message => ucfirst($type) . ' notification settings updated.',
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub test_notification {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type');

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $self->render_error($c, 'Invalid notification type', 400);
            return;
        }

        # Rebuild notifiers to pick up latest settings
        $self->rebuild_notifiers->();

        my $notifiers = $self->notifiers;
        unless ($notifiers->{$type}) {
            $c->render(json => {
                success => 0,
                error   => ucfirst($type) . ' is not configured',
            }, status => 400);
            return;
        }

        my $result = eval { $notifiers->{$type}->send_test() };
        if ($@ || !$result) {
            $c->render(json => {
                success => 0,
                error   => $@ // 'Test failed',
            });
        } else {
            $c->render(json => {
                success => 1,
                message => 'Test notification sent successfully',
            });
        }
    });
}

sub update_retention {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $self->render_error($c, 'days required', 400);
            return;
        }

        if ($self->settings->is_from_env('retention', 'days')) {
            $c->render(json => {
                error    => 'Cannot modify - configured via PURL_RETENTION_DAYS',
                from_env => 1,
            }, status => 400);
            return;
        }

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $self->render_error($c, 'days must be between 1 and 365', 400);
            return;
        }

        if ($self->settings->set('retention', 'days', $days)) {
            # Update ClickHouse TTL
            eval { $self->storage->update_retention($days) };

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

Purl::API::Controller::Settings - Settings management endpoints

=head1 DESCRIPTION

Handles ClickHouse, retention, and notification settings.

=cut

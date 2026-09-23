package Purl::API::Controller::Settings::Notifications;
use strict;
use warnings;
use 5.024;

use Moo;
use Purl::Util::ErrorResponse qw(strip_location);
use namespace::clean;
use Mojo::JSON qw(decode_json);
use Purl::Alert::Telegram ();   # valid_thread_id — see update_notifications

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

sub update_notifications {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $type = $c->param('type');

        unless (defined $type) {
            $self->render_error($c, 'Notification type parameter required', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };

        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $self->render_error($c, 'Invalid notification type', 400);
            return;
        }

        # A topic id the Bot API would reject is refused HERE rather than
        # stored. thread_id spent its whole life being written and never read
        # (#71); accepting a value the channel drops on every send is the same
        # lie in a smaller box. Blank stays legal — it means "the General
        # topic". The predicate lives on the channel so the boundary and the
        # sender cannot drift apart.
        if ($type eq 'telegram'
            && !$self->settings->value_is_blank($body->{thread_id})
            && !Purl::Alert::Telegram::valid_thread_id($body->{thread_id})) {
            $self->render_error($c,
                'thread_id must be a positive integer (Telegram forum topic id)', 400);
            return;
        }

        # Channel fields are nested one level deeper, so a clear instruction is
        # addressed by the same dotted name (`clear_bot_token` -> the key
        # 'telegram.bot_token'). Runs first so the clear_* fields never reach
        # the guard as proposed values, nor the file as config keys.
        my $clear = $self->take_clear_requests($c, 'notifications', $body,
            prefix => "$type.") or return;

        # Notification keys are nested one level deeper, so they are addressed
        # by their dotted name — the same form %ENV_MAP uses. The hardcoded
        # check this replaces only knew about the bot_token / webhook_url of
        # each channel, so PURL_TELEGRAM_CHAT_ID, PURL_SLACK_CHANNEL and
        # PURL_ALERT_WEBHOOK_TOKEN edits were reported as saved and were not.
        my %changes = map { ("$type.$_" => $body->{$_}) } keys %$body;
        return if $self->reject_env_managed($c, 'notifications', \%changes);

        # What may actually go to disk is Purl::Config's decision, not ours:
        # update_section runs the section through _writable_values, which walks
        # nested keys by their dotted name and — crucially — RESTORES the file's
        # value for an ENV-owned key instead of dropping it. The hand-written
        # delete loop that used to live here dropped it, so one save under
        # PURL_TELEGRAM_CHAT_ID erased the chat_id settings.json held and the
        # day the variable came off, Telegram alerts stopped silently.
        #
        # update_section (not set_section) because it re-reads under the lock:
        # a concurrent save to another channel is no longer lost.
        #
        # Erase first — see Settings::update_clickhouse. Once the stored secret is gone
        # there is nothing for _writable_values to restore behind the blank
        # field the UI always posts.
        $self->settings->clear_secrets('notifications', @$clear);

        my $saved = $self->settings->update_section('notifications', sub {
            my ($current) = @_;
            $current->{$type} = { %$body };
            return;
        });

        if ($saved) {
            # Rebuild notifiers
            $self->rebuild_notifiers->();
            $c->audit_event(action => 'update_settings', resource_type => 'settings',
                resource_id => "notifications.$type");

            $c->render(json => {
                status  => 'ok',
                message => ucfirst($type) . ' notification settings updated.',
                cleared => $clear,
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub test_notification {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

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
                error   => ($@ ? strip_location($@) : q{Test failed}),
            });
        } else {
            $c->render(json => {
                success => 1,
                message => 'Test notification sent successfully',
            });
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::Notifications - notification channel settings (Telegram, Slack,
webhook) and test sends

=cut

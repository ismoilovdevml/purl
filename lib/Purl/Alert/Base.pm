package Purl::Alert::Base;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

requires 'deliver';

has 'name' => (
    is       => 'ro',
    required => 1,
);

has 'enabled' => (
    is      => 'rw',
    default => 1,
);

has 'throttle_seconds' => (
    is      => 'ro',
    default => 60,
);

has 'max_retries' => (
    is      => 'ro',
    default => 3,
);

has '_last_sent' => (
    is      => 'rw',
    default => 0,
);

# Per-alert throttle state: maps alert_id => last_sent_time
has '_last_sent_by_alert' => (
    is      => 'rw',
    default => sub { {} },
);

sub can_send {
    my ($self) = @_;
    return 0 unless $self->enabled;
    return 1 if time() - $self->_last_sent >= $self->throttle_seconds;
    return 0;
}

# Per-alert throttle with optional per-alert override period
sub is_throttled {
    my ($self, $alert_id, $throttle_override_seconds) = @_;
    return 1 unless $self->enabled;
    my $period = (defined $throttle_override_seconds && $throttle_override_seconds > 0)
        ? $throttle_override_seconds
        : $self->throttle_seconds;
    my $last = $self->_last_sent_by_alert->{$alert_id} // 0;
    return (time() - $last) < $period ? 1 : 0;
}

sub _mark_sent {
    my ($self, $alert_id) = @_;
    $self->_last_sent_by_alert->{$alert_id} = time();
    $self->_last_sent(time());
}

# Retry wrapper with exponential backoff (1s, 2s, 4s).
# 4xx responses are not retried; 5xx and connection failures are.
sub _send_with_retry {
    my ($self, $send_sub) = @_;
    for my $attempt (0 .. $self->max_retries - 1) {
        my $result = eval { $send_sub->() };
        my $err    = $@;
        if (!$err && $result) {
            if (ref $result eq 'HASH' && exists $result->{status}) {
                return $result if $result->{success};
                my $status = $result->{status};
                if ($status >= 400 && $status < 500) {
                    warn "Alert send failed with client error ($status) — not retrying";
                    return 0;
                }
                warn sprintf("Alert send failed (attempt %d/%d): HTTP %d",
                    $attempt + 1, $self->max_retries, $status);
            } else {
                return $result;
            }
        } else {
            warn sprintf("Alert send failed (attempt %d/%d)%s",
                $attempt + 1, $self->max_retries, $err ? ": $err" : '');
        }
        sleep(2 ** $attempt) if $attempt < $self->max_retries - 1;
    }
    return 0;
}

sub notify {
    my ($self, $alert, $context) = @_;

    return 0 unless $self->can_send;

    my $message = $self->format_message($alert, $context);
    my $result = $self->deliver($message);

    if ($result) {
        $self->_last_sent(time());
    }

    return $result;
}

sub format_message {
    my ($self, $alert, $context) = @_;

    my $count = $context->{count} // 0;
    my $threshold = $alert->{threshold} // 0;
    my $window = $alert->{window_minutes} // 5;
    my $query = $alert->{query} // '';

    return {
        title     => "Alert: $alert->{name}",
        alert     => $alert->{name},
        query     => $query,
        count     => $count,
        threshold => $threshold,
        window    => $window,
        time      => scalar localtime(),
        severity  => $count >= $threshold * 2 ? 'critical' : 'warning',
    };
}

1;

__END__

=head1 NAME

Purl::Alert::Base - Base role for alert notifiers

=head1 SYNOPSIS

    package Purl::Alert::MyNotifier;
    use Moo;
    with 'Purl::Alert::Base';

    sub send {
        my ($self, $message) = @_;
        # Send notification
        return 1;
    }

=cut

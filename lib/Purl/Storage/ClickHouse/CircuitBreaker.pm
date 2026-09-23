package Purl::Storage::ClickHouse::CircuitBreaker;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use Time::HiRes qw(time);
use namespace::clean;

# Circuit breaker state
has '_circuit_state' => (
    is      => 'rw',
    default => 'closed',  # closed, open, half_open
);

has '_consecutive_failures' => (
    is      => 'rw',
    default => 0,
);

has '_circuit_opened_at' => (
    is      => 'rw',
    default => 0,
);

has '_circuit_failure_threshold' => (
    is      => 'ro',
    default => 3,
);

has '_circuit_cooldown' => (
    is      => 'ro',
    default => 30,  # seconds
);

# Refuse the call outright while the breaker is open; flip to half_open once
# the cooldown has elapsed so the next call gets to probe the server.
sub _circuit_guard {
    my ($self) = @_;
    return unless $self->_circuit_state eq 'open';
    if (time() - $self->_circuit_opened_at >= $self->_circuit_cooldown) {
        $self->_circuit_state('half_open');
        return;
    }
    die "ClickHouse circuit breaker is open — service unavailable";
}

# Record the outcome of one ClickHouse round-trip. Shared by every transport
# path (_query, _query_to_file, _post_file) so a streaming export can trip and
# reset the breaker exactly like a normal query — there is only one breaker.
sub _circuit_record {
    my ($self, $ok, $elapsed) = @_;

    $self->_metrics->{queries_total}++;
    $self->_metrics->{query_time_total} += $elapsed;

    unless ($ok) {
        $self->_metrics->{errors_total}++;
        $self->_consecutive_failures($self->_consecutive_failures + 1);
        if ($self->_consecutive_failures >= $self->_circuit_failure_threshold) {
            $self->_circuit_state('open');
            $self->_circuit_opened_at(time());
            warn "ClickHouse circuit breaker OPENED after $self->{_consecutive_failures} consecutive failures";
        }
        return;
    }

    if ($self->_circuit_state ne 'closed') {
        warn "ClickHouse circuit breaker CLOSED — connection recovered";
    }
    $self->_consecutive_failures(0);
    $self->_circuit_state('closed');
    return;
}

sub circuit_breaker_status {
    my ($self) = @_;
    return {
        state              => $self->_circuit_state,
        consecutive_failures => $self->_consecutive_failures,
        cooldown_remaining => $self->_circuit_state eq 'open'
            ? int($self->_circuit_cooldown - (time() - $self->_circuit_opened_at))
            : 0,
    };
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::CircuitBreaker - the single ClickHouse circuit breaker shared by every
transport path in L<Purl::Storage::ClickHouse::Connection>.

=cut

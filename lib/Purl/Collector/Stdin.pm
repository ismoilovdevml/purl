package Purl::Collector::Stdin;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use IO::Select;

with 'Purl::Collector::Base';

has '_select' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { IO::Select->new(\*STDIN) },
);

sub BUILD {
    my ($self) = @_;
    # Set STDIN to non-blocking if possible
    eval {
        require Fcntl;
        my $flags = fcntl(STDIN, Fcntl::F_GETFL(), 0);
        fcntl(STDIN, Fcntl::F_SETFL(), $flags | Fcntl::O_NONBLOCK());
    };
}

sub start {
    my ($self) = @_;
    $self->_running(1);
}

sub stop {
    my ($self) = @_;
    $self->_running(0);
}

sub is_running {
    my ($self) = @_;
    return $self->_running;
}

# Read available lines
sub read_lines {
    my ($self, $max_lines) = @_;

    $max_lines //= 1000;

    return [] unless $self->_running;

    my @lines;

    while (defined(my $line = <STDIN>)) {
        chomp $line;
        push @lines, $line if length $line;

        $self->on_line->($line, $self);

        last if @lines >= $max_lines;
    }

    # Check for EOF
    if (eof(STDIN)) {
        $self->_running(0);
    }

    return \@lines;
}

# Poll for new lines
sub poll {
    my ($self, $timeout) = @_;

    $timeout //= 0.1;

    return unless $self->_running;

    if ($self->_select->can_read($timeout)) {
        return $self->read_lines();
    }

    return [];
}

1;

__END__

=head1 NAME

Purl::Collector::Stdin - Read logs from standard input

=head1 SYNOPSIS

    use Purl::Collector::Stdin;

    my $collector = Purl::Collector::Stdin->new(
        name => 'stdin',
        format => 'auto',
        on_line => sub {
            my ($line, $collector) = @_;
            print "Got: $line\n";
        },
    );

    $collector->start();

    while ($collector->is_running) {
        $collector->poll(1);
    }

=cut

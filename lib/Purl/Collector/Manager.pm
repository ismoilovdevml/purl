package Purl::Collector::Manager;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Purl::Collector::File;
use Purl::Collector::Stdin;
use Purl::Parser::Engine;
use Purl::Parser::Normalizer;

has 'collectors' => (
    is      => 'rw',
    default => sub { {} },
);

has 'parser' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Purl::Parser::Engine->new() },
);

has 'normalizer' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { Purl::Parser::Normalizer->new() },
);

has 'on_log' => (
    is      => 'rw',
    default => sub { sub {} },
);

has 'on_error' => (
    is      => 'rw',
    default => sub { sub {} },
);

has 'batch_size' => (
    is      => 'rw',
    default => 100,
);

has '_buffer' => (
    is      => 'rw',
    default => sub { [] },
);

# Add a collector from config
sub add_source {
    my ($self, $config) = @_;

    my $name = $config->{name} or die "Source name required";
    my $type = $config->{type} // 'file';

    my $collector;

    if ($type eq 'file') {
        $collector = Purl::Collector::File->new(
            name           => $name,
            path           => $config->{path},
            format         => $config->{format} // 'auto',
            tags           => $config->{tags} // {},
            from_beginning => $config->{from_beginning} // 0,
            on_line        => sub { $self->_handle_line(@_) },
            on_error       => sub { $self->on_error->(@_) },
        );
    }
    elsif ($type eq 'stdin') {
        $collector = Purl::Collector::Stdin->new(
            name     => $name,
            format   => $config->{format} // 'auto',
            tags     => $config->{tags} // {},
            on_line  => sub { $self->_handle_line(@_) },
            on_error => sub { $self->on_error->(@_) },
        );
    }
    else {
        die "Unknown collector type: $type";
    }

    $self->collectors->{$name} = $collector;

    return $collector;
}

# Remove a collector
sub remove_source {
    my ($self, $name) = @_;

    my $collector = delete $self->collectors->{$name};
    if ($collector && $collector->is_running) {
        $collector->stop();
    }

    return $collector;
}

# Start all collectors
sub start_all {
    my ($self) = @_;

    for my $collector (values %{$self->collectors}) {
        $collector->start();
    }
}

# Stop all collectors
sub stop_all {
    my ($self) = @_;

    for my $collector (values %{$self->collectors}) {
        $collector->stop();
    }

    # Flush remaining buffer
    $self->_flush_buffer();
}

# Poll all collectors once
sub poll_all {
    my ($self, $timeout) = @_;

    $timeout //= 0.1;

    for my $collector (values %{$self->collectors}) {
        next unless $collector->is_running;
        $collector->poll($timeout / scalar(keys %{$self->collectors}) || $timeout);
    }

    # Flush buffer if full
    if (@{$self->_buffer} >= $self->batch_size) {
        $self->_flush_buffer();
    }
}

# Run collector loop
sub run {
    my ($self, $poll_interval) = @_;

    $poll_interval //= 0.1;

    $self->start_all();

    while ($self->_has_running_collectors()) {
        $self->poll_all($poll_interval);
    }

    $self->stop_all();
}

# Handle incoming line
sub _handle_line {
    my ($self, $line, $collector) = @_;

    return unless defined $line && length $line;

    # Parse the line
    my $parsed = $self->parser->parse($line, $collector->format);
    return unless $parsed;

    # Normalize to unified schema
    my $normalized = $self->normalizer->normalize($parsed, $collector->tags);
    return unless $normalized;

    # Add source info
    $normalized->{meta}{_source} = $collector->name;

    # Add to buffer
    push @{$self->_buffer}, $normalized;

    # Flush if buffer is full
    if (@{$self->_buffer} >= $self->batch_size) {
        $self->_flush_buffer();
    }
}

# Flush buffer to callback
sub _flush_buffer {
    my ($self) = @_;

    return unless @{$self->_buffer};

    my @logs = @{$self->_buffer};
    $self->_buffer([]);

    # Call callback with batch
    $self->on_log->(\@logs);
}

# Check if any collectors are running
sub _has_running_collectors {
    my ($self) = @_;

    for my $collector (values %{$self->collectors}) {
        return 1 if $collector->is_running;
    }

    return 0;
}

# Get collector by name
sub get_collector {
    my ($self, $name) = @_;
    return $self->collectors->{$name};
}

# List all collector names
sub list_collectors {
    my ($self) = @_;
    my @names = sort keys %{$self->collectors};
    return @names;
}

1;

__END__

=head1 NAME

Purl::Collector::Manager - Manage multiple log collectors

=head1 SYNOPSIS

    use Purl::Collector::Manager;

    my $manager = Purl::Collector::Manager->new(
        on_log => sub {
            my ($logs) = @_;  # Array of normalized logs
            for my $log (@$logs) {
                $storage->insert($log);
            }
        },
    );

    # Add sources from config
    $manager->add_source({
        name   => 'nginx-access',
        type   => 'file',
        path   => '/var/log/nginx/access.log',
        format => 'nginx_combined',
        tags   => { service => 'nginx' },
    });

    # Run collection loop
    $manager->run();

=cut

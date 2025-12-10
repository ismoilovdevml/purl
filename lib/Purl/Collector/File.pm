package Purl::Collector::File;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Path::Tiny;
use IO::Select;

with 'Purl::Collector::Base';

has 'path' => (
    is       => 'ro',
    required => 1,
);

has 'from_beginning' => (
    is      => 'ro',
    default => 0,
);

has 'poll_interval' => (
    is      => 'ro',
    default => 0.1,  # seconds
);

has '_fh' => (
    is      => 'rw',
    clearer => '_clear_fh',
);

has '_inode' => (
    is      => 'rw',
    default => 0,
);

has '_position' => (
    is      => 'rw',
    default => 0,
);

sub start {
    my ($self) = @_;

    return if $self->_running;

    $self->_open_file();
    $self->_running(1);
}

sub stop {
    my ($self) = @_;

    $self->_running(0);

    if ($self->_fh) {
        close($self->_fh);
        $self->_clear_fh;
    }
}

sub is_running {
    my ($self) = @_;
    return $self->_running;
}

sub _open_file {
    my ($self) = @_;

    my $path = $self->path;

    unless (-e $path) {
        $self->on_error->("File does not exist: $path");
        return;
    }

    open my $fh, '<', $path or do {
        $self->on_error->("Cannot open $path: $!");
        return;
    };

    # Get inode for rotation detection
    my @stat = stat($fh);
    $self->_inode($stat[1]);

    # Seek to end unless reading from beginning
    unless ($self->from_beginning) {
        seek($fh, 0, 2);  # SEEK_END
    }

    $self->_position(tell($fh));
    $self->_fh($fh);
}

# Read available lines (non-blocking)
sub read_lines {
    my ($self, $max_lines) = @_;

    $max_lines //= 1000;

    return [] unless $self->_running && $self->_fh;

    # Check for file rotation
    $self->_check_rotation();

    my $fh = $self->_fh;
    return [] unless $fh;

    my @lines;

    while (my $line = <$fh>) {
        chomp $line;
        push @lines, $line if length $line;
        last if @lines >= $max_lines;
    }

    $self->_position(tell($fh));

    # Call callback for each line
    for my $line (@lines) {
        $self->on_line->($line, $self);
    }

    return \@lines;
}

# Poll for new lines (blocking with timeout)
sub poll {
    my ($self, $timeout) = @_;

    $timeout //= $self->poll_interval;

    return unless $self->_running;

    my $fh = $self->_fh;
    return unless $fh;

    my $select = IO::Select->new($fh);

    if ($select->can_read($timeout)) {
        return $self->read_lines();
    }

    # Even if select times out, try to read (for regular files)
    return $self->read_lines();
}

# Check if file was rotated
sub _check_rotation {
    my ($self) = @_;

    my $path = $self->path;
    return unless -e $path;

    my @stat = stat($path);
    my $current_inode = $stat[1];

    # File was rotated (different inode)
    if ($current_inode != $self->_inode) {
        $self->_reopen_file();
        return;
    }

    # File was truncated (smaller than our position)
    my $size = $stat[7];
    if ($size < $self->_position) {
        seek($self->_fh, 0, 0);  # SEEK_SET
        $self->_position(0);
    }
}

sub _reopen_file {
    my ($self) = @_;

    if ($self->_fh) {
        close($self->_fh);
        $self->_clear_fh;
    }

    $self->_open_file();
}

1;

__END__

=head1 NAME

Purl::Collector::File - Tail log files

=head1 SYNOPSIS

    use Purl::Collector::File;

    my $collector = Purl::Collector::File->new(
        name => 'nginx-access',
        path => '/var/log/nginx/access.log',
        format => 'nginx_combined',
        on_line => sub {
            my ($line, $collector) = @_;
            print "Got: $line\n";
        },
    );

    $collector->start();

    while ($collector->is_running) {
        $collector->poll(1);  # 1 second timeout
    }

=cut

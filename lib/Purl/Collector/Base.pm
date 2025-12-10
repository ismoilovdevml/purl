package Purl::Collector::Base;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

requires 'start';
requires 'stop';
requires 'is_running';

has 'name' => (
    is       => 'ro',
    required => 1,
);

has 'format' => (
    is      => 'rw',
    default => 'auto',
);

has 'tags' => (
    is      => 'rw',
    default => sub { {} },
);

has 'on_line' => (
    is      => 'rw',
    default => sub { sub {} },
);

has 'on_error' => (
    is      => 'rw',
    default => sub { sub {} },
);

has '_running' => (
    is      => 'rw',
    default => 0,
);

1;

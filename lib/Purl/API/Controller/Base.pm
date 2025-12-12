package Purl::API::Controller::Base;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

has 'storage' => (
    is       => 'ro',
    required => 1,
);

has 'config' => (
    is => 'ro',
    default => sub { {} },
);

has 'cache' => (
    is => 'rw',
    default => sub { {} },
);

sub get_cached {
    my ($self, $key) = @_;
    my $entry = $self->cache->{$key};
    return unless $entry;
    return if $entry->{expires} < time();
    return $entry->{value};
}

sub set_cached {
    my ($self, $key, $value, $ttl) = @_;
    $ttl //= 60;
    $self->cache->{$key} = {
        value   => $value,
        expires => time() + $ttl,
    };
    return $value;
}

sub render_error {
    my ($self, $c, $message, $code) = @_;
    $code //= 500;
    
    # Log the error if it's a 500
    if ($code >= 500) {
        $c->app->log->error($message);
    }
    
    $c->render(json => { error => $message }, status => $code);
}

sub safe_execute {
    my ($self, $c, $cb) = @_;
    
    eval {
        $cb->();
    };
    if ($@) {
        $self->render_error($c, "Internal Server Error: $@", 500);
    }
}

1;

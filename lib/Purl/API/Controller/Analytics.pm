package Purl::API::Controller::Analytics;
use strict;
use warnings;
use 5.024;
use Moo;
extends 'Purl::API::Controller::Base';

# Extra dependencies
has 'notifier_list' => (
    is       => 'ro',
    default  => sub { {} },
);

sub tables {
    my ($self, $c) = @_;

    my $cache_key = 'analytics_tables';
    if (my $cached = $self->get_cached($cache_key)) {
        $c->res->headers->header('X-Cache' => 'HIT');
        $c->render(json => $cached);
        return;
    }

    my $tables = $self->storage->get_table_stats();
    my $response = { tables => $tables };

    $self->set_cached($cache_key, $response, 60);
    $c->res->headers->header('X-Cache' => 'MISS');

    $c->render(json => $response);
}

sub queries {
    my ($self, $c) = @_;
    my $limit = $c->param('limit') // 10;

    my $cache_key = "analytics_queries:$limit";
    if (my $cached = $self->get_cached($cache_key)) {
        $c->res->headers->header('X-Cache' => 'HIT');
        $c->render(json => $cached);
        return;
    }

    my $queries = $self->storage->get_slow_queries(int($limit));
    my $response = { queries => $queries };

    $self->set_cached($cache_key, $response, 30);
    $c->res->headers->header('X-Cache' => 'MISS');

    $c->render(json => $response);
}

sub notifiers {
    my ($self, $c) = @_;
    my %status;
    
    my $notifiers = $self->notifier_list;

    for my $type (keys %$notifiers) {
        $status{$type} = {
            configured => 1,
            name       => $notifiers->{$type}->name,
        };
    }

    $c->render(json => {
        notifiers => \%status,
        available => [qw(telegram slack webhook)],
    });
}

1;

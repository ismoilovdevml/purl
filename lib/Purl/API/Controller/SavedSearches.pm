package Purl::API::Controller::SavedSearches;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $searches = $self->storage->get_saved_searches();
        $c->render(json => { searches => $searches });
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name} && $body->{query}) {
            $self->render_error($c, 'Name and query required', 400);
            return;
        }

        $self->storage->create_saved_search(
            $body->{name},
            $body->{query},
            $body->{time_range}
        );

        $c->render(json => { status => 'ok' });
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $id = $c->param('id');

        unless ($id) {
            $self->render_error($c, 'ID required', 400);
            return;
        }

        $self->storage->delete_saved_search($id);
        $c->render(json => { status => 'ok' });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::SavedSearches - Saved searches CRUD endpoints

=head1 DESCRIPTION

Handles saving, listing, and deleting user search queries.

=cut

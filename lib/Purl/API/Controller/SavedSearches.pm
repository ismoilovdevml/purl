package Purl::API::Controller::SavedSearches;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# READS ARE NEVER GATED. Saved searches are on the free plan, and even if they
# were not, locking a user out of data they already created is a support ticket,
# not a paywall. Only creation is metered.
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

        # Validate the query with the SAME rule the search endpoints use, so a
        # search can never be saved that 400s the moment someone runs it.
        # _apply_query lives in Controller::Base precisely so this is a reuse
        # and not a second, drifting copy of the rule.
        my %probe;
        return unless $self->_apply_query($c, \%probe, $body->{query});

        # Quota, not feature gate: every plan may save searches, plans differ
        # only in how many. -1 (all current plans) means unlimited.
        my $existing = $self->storage->get_saved_searches() // [];
        return unless $self->check_limit($c, 'saved_searches', scalar @$existing);

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

package Purl::API::Routes::SavedSearches;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_saved_search_routes);

# ============================================
# Saved Searches Routes Setup
# ============================================

sub setup_saved_search_routes {
    my ($protected, $storage) = @_;

    # List saved searches
    $protected->get('/saved-searches' => sub {
        my ($c) = @_;
        my $searches = $storage->get_saved_searches();
        $c->render(json => { searches => $searches });
    });

    # Create saved search
    $protected->post('/saved-searches' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{name} && $body->{query}) {
            $c->render(json => { error => 'Name and query required' }, status => 400);
            return;
        }

        $storage->create_saved_search($body->{name}, $body->{query}, $body->{time_range});
        $c->render(json => { status => 'ok' });
    });

    # Delete saved search
    $protected->delete('/saved-searches/:id' => sub {
        my ($c) = @_;
        my $id = $c->param('id');
        $storage->delete_saved_search($id);
        $c->render(json => { status => 'ok' });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::SavedSearches - Saved searches CRUD routes

=cut

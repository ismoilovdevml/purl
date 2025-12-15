package Purl::API::Routes::SavedSearches;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_saved_search_routes);

sub setup_saved_search_routes {
    my ($protected, $args) = @_;

    my $storage = $args->{storage};

    $protected->get('/saved-searches' => sub {
        my ($c) = @_;
        $c->render(json => { searches => $storage->get_saved_searches() });
    });

    $protected->post('/saved-searches' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'Name and query required' }, status => 400) unless $body && $body->{name} && $body->{query};
        $storage->create_saved_search($body->{name}, $body->{query}, $body->{time_range});
        $c->render(json => { status => 'ok' });
    });

    $protected->delete('/saved-searches/:id' => sub {
        my ($c) = @_;
        $storage->delete_saved_search($c->param('id'));
        $c->render(json => { status => 'ok' });
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::SavedSearches - Saved searches CRUD routes

=cut

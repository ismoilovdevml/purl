package Purl::API::Controller::Clusters;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Digest::MD5 qw(md5_hex);
use Mojo::JSON qw(encode_json);

extends 'Purl::API::Controller::Base';

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        # Check cache first
        my $cache_key = 'clusters_list';
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        # The materialised `cluster` column (K8sColumns), bounded to the last day:
        # a cluster that has sent nothing for 24 h is not worth offering, and an
        # unbounded scan grows with retention (#108).
        my $sql = q{
            SELECT DISTINCT cluster
            FROM logs
            WHERE timestamp >= now() - INTERVAL 1 DAY
              AND cluster != ''
            ORDER BY cluster
            LIMIT 1000
        };

        my $rows = $self->storage->_query_json($sql, no_cache => 1);
        my @clusters = map { $_->{cluster} } @$rows;

        my $response = { clusters => \@clusters };

        # Cache for 60 seconds
        $self->set_cached($cache_key, $response, 60);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Clusters - Multi-cluster discovery controller

=head1 DESCRIPTION

Returns unique cluster names from log metadata for multi-cluster filtering.

=cut

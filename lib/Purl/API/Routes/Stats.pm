package Purl::API::Routes::Stats;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

our @EXPORT_OK = qw(setup_stats_routes);

# ============================================
# Statistics Routes Setup
# ============================================

sub setup_stats_routes {
    my ($protected, $storage, $cache_funcs) = @_;

    my ($cache_get, $cache_set) = @$cache_funcs;

    # Field statistics (with caching)
    $protected->get('/stats/fields/:field' => sub {
        my ($c) = @_;
        my $field = $c->param('field');
        my $limit = $c->param('limit') // 10;
        my $from  = $c->param('from');
        my $to    = $c->param('to');

        # Support both top-level fields and meta.* fields for K8s
        unless ($field =~ /^(level|service|host|meta\.(namespace|pod|container|node|cluster))$/) {
            $c->render(json => { error => 'Invalid field' }, status => 400);
            return;
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $cache_key = "field_stats:$field:" . md5_hex(encode_json(\%params));
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $storage->field_stats($field, %params);

        my $response = {
            field  => $field,
            values => $stats,
        };

        $cache_set->($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Time histogram (with caching)
    $protected->get('/stats/histogram' => sub {
        my ($c) = @_;
        my $interval = $c->param('interval') // '1 hour';
        my $from     = $c->param('from');
        my $to       = $c->param('to');
        my $level    = $c->param('level');
        my $service  = $c->param('service');

        my %params = (interval => $interval);
        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;

        my $cache_key = "histogram:" . md5_hex(encode_json(\%params));
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $histogram = $storage->histogram(%params);

        my $response = {
            interval => $interval,
            buckets  => $histogram,
        };

        $cache_set->($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Available fields
    $protected->get('/fields' => sub {
        my ($c) = @_;
        my $fields = $storage->get_fields();
        $c->render(json => { fields => $fields });
    });

    # Database stats
    $protected->get('/stats' => sub {
        my ($c) = @_;
        my $cache_key = 'db_stats';
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $storage->stats();
        $cache_set->($cache_key, $stats, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $stats);
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Stats - Field statistics and histogram routes

=cut

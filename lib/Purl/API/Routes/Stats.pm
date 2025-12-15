package Purl::API::Routes::Stats;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

use Purl::Utils qw(parse_time_range);
use Purl::API::Middleware qw(cache_get cache_set);

our @EXPORT_OK = qw(setup_stats_routes);

sub setup_stats_routes {
    my ($protected, $args) = @_;

    my $storage = $args->{storage};

    $protected->get('/stats/fields/#field' => sub {
        my ($c) = @_;
        my $field = $c->param('field');
        my $limit = $c->param('limit') // 10;
        my ($from, $to) = ($c->param('from'), $c->param('to'));
        ($from, $to) = parse_time_range($c->param('range')) if $c->param('range');

        unless ($field =~ /^(level|service|host|meta\.(namespace|pod|node|container|cluster))$/) {
            return $c->render(json => { error => 'Invalid field' }, status => 400);
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to} = $to if $to;

        my $cache_key = "field_stats:$field:" . md5_hex(encode_json(\%params));
        if (my $cached = cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            return $c->render(json => $cached);
        }

        my $stats = $storage->field_stats($field, %params);
        my $response = { field => $field, values => $stats };
        cache_set($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $response);
    });

    $protected->get('/stats/histogram' => sub {
        my ($c) = @_;
        my $interval = $c->param('interval') // '1 hour';
        my ($from, $to) = ($c->param('from'), $c->param('to'));
        ($from, $to) = parse_time_range($c->param('range')) if $c->param('range');

        my %params = (interval => $interval);
        $params{from} = $from if $from;
        $params{to} = $to if $to;
        $params{level} = $c->param('level') if $c->param('level');
        $params{service} = $c->param('service') if $c->param('service');

        my $cache_key = "histogram:" . md5_hex(encode_json(\%params));
        if (my $cached = cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            return $c->render(json => $cached);
        }

        my $histogram = $storage->histogram(%params);
        my $response = { interval => $interval, buckets => $histogram };
        cache_set($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $response);
    });

    $protected->get('/fields' => sub {
        my ($c) = @_;
        $c->render(json => { fields => $storage->get_fields() });
    });

    $protected->get('/stats' => sub {
        my ($c) = @_;
        my $cache_key = 'db_stats';
        if (my $cached = cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            return $c->render(json => $cached);
        }
        my $stats = $storage->stats();
        cache_set($cache_key, $stats, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $stats);
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Stats - Field statistics and histogram routes

=cut

package Purl::API::Controller::Stats;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

use Purl::Util::Time qw(parse_time_range);

extends 'Purl::API::Controller::Base';

sub field_stats {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $field = $c->param('field');
        my $limit = $c->param('limit') // 10;
        my $from  = $c->param('from');
        my $to    = $c->param('to');

        if (my $range = $c->param('range')) {
            ($from, $to) = parse_time_range($range);
        }

        # Validate field (allow standard fields and meta.* K8s fields)
        unless ($field =~ /^(level|service|host|meta\.(namespace|pod|node|container|cluster))$/) {
            $self->render_error($c, 'Invalid field', 400);
            return;
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $cache_key = "field_stats:$field:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $self->storage->field_stats($field, %params);

        my $response = {
            field  => $field,
            values => $stats,
        };

        $self->set_cached($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });
}

sub histogram {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $interval = $c->param('interval') // '1 hour';
        my $from     = $c->param('from');
        my $to       = $c->param('to');
        my $level    = $c->param('level');
        my $service  = $c->param('service');

        if (my $range = $c->param('range')) {
            ($from, $to) = parse_time_range($range);
        }

        my %params = (interval => $interval);
        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;

        my $cache_key = "histogram:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $histogram = $self->storage->histogram(%params);

        my $response = {
            interval => $interval,
            buckets  => $histogram,
        };

        $self->set_cached($cache_key, $response, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });
}

sub fields {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $fields = $self->storage->get_fields();
        $c->render(json => { fields => $fields });
    });
}

sub db_stats {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $cache_key = 'db_stats';
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $self->storage->stats();
        $self->set_cached($cache_key, $stats, 30);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $stats);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Stats - Statistics and metrics endpoints

=head1 DESCRIPTION

Handles field statistics, histograms, and database stats.

=cut

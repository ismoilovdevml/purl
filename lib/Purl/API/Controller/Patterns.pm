package Purl::API::Controller::Patterns;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

use Purl::Util::Time qw(parse_time_range);

extends 'Purl::API::Controller::Base';

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $limit   = $c->param('limit') // 30;
        my $service = $c->param('service');
        my $level   = $c->param('level');
        my $from    = $c->param('from');
        my $to      = $c->param('to');

        if (my $range = $c->param('range')) {
            ($from, $to) = parse_time_range($range);
        }

        my %params = (limit => int($limit));
        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{service} = $service if $service;
        $params{level}   = $level if $level;

        my $cache_key = "patterns:" . md5_hex(encode_json(\%params));
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            # Return raw JSON if stored
            if (ref $cached eq 'HASH' && $cached->{raw_json}) {
                $c->res->headers->content_type('application/json');
                $c->render(data => $cached->{raw_json});
                return;
            }
            $c->render(json => $cached);
            return;
        }

        my $patterns = $self->storage->get_patterns(%params);

        # Build JSON manually to ensure pattern_hash is string (avoid JS BigInt precision loss)
        my @pattern_json;
        for my $p (@$patterns) {
            my $hash_str = $p->{pattern_hash};
            my $pattern_escaped = $p->{pattern} =~ s/([\\"])/\\$1/gr;
            my $sample_escaped = ($p->{sample_message} // '') =~ s/([\\"])/\\$1/gr;
            push @pattern_json, sprintf(
                '{"pattern_hash":"%s","pattern":"%s","sample_message":"%s","service":"%s","level":"%s","first_seen":"%s","last_seen":"%s","count":%d}',
                $hash_str, $pattern_escaped, $sample_escaped,
                $p->{service}, $p->{level}, $p->{first_seen}, $p->{last_seen}, $p->{count}
            );
        }
        my $json = '{"patterns":[' . join(',', @pattern_json) . '],"total":' . scalar(@$patterns) . '}';

        $self->set_cached($cache_key, { raw_json => $json }, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->res->headers->content_type('application/json');

        $c->render(data => $json);
    });
}

sub logs {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $hash  = $c->param('hash');
        my $limit = $c->param('limit') // 100;
        my $from  = $c->param('from');
        my $to    = $c->param('to');

        unless ($hash && $hash =~ /^\d+$/) {
            $self->render_error($c, 'Invalid pattern hash', 400);
            return;
        }

        if (my $range = $c->param('range')) {
            ($from, $to) = parse_time_range($range);
        }

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        my $result = $self->storage->get_pattern_logs($hash, %params);

        $c->render(json => {
            pattern_hash => $hash,
            hits         => $result->{hits},
            total        => $result->{total},
        });
    });
}

sub stats {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $cache_key = 'pattern_stats';
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $stats = $self->storage->get_pattern_stats();
        $self->set_cached($cache_key, $stats, 60);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $stats);
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Patterns - Log pattern analysis endpoints

=head1 DESCRIPTION

Handles log pattern detection, grouping, and analysis.

=cut

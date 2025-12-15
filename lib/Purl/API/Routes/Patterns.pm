package Purl::API::Routes::Patterns;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(encode_json);
use Digest::MD5 qw(md5_hex);

use Purl::Utils qw(parse_time_range);
use Purl::API::Middleware qw(cache_get cache_set);

our @EXPORT_OK = qw(setup_pattern_routes);

sub setup_pattern_routes {
    my ($protected, $args) = @_;

    my $storage = $args->{storage};

    $protected->get('/patterns' => sub {
        my ($c) = @_;
        my $limit = $c->param('limit') // 30;
        my ($from, $to) = ($c->param('from'), $c->param('to'));
        ($from, $to) = parse_time_range($c->param('range')) if $c->param('range');

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to} = $to if $to;
        $params{service} = $c->param('service') if $c->param('service');
        $params{level} = $c->param('level') if $c->param('level');

        my $cache_key = "patterns:" . md5_hex(encode_json(\%params));
        if (my $cached = cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            return $c->render(json => $cached);
        }

        my $patterns = $storage->get_patterns(%params);
        my @pattern_json;
        for my $p (@$patterns) {
            my $pattern_escaped = $p->{pattern} =~ s/([\\"])/\\$1/gr;
            my $sample_escaped = ($p->{sample_message} // '') =~ s/([\\"])/\\$1/gr;
            push @pattern_json, sprintf('{"pattern_hash":"%s","pattern":"%s","sample_message":"%s","service":"%s","level":"%s","first_seen":"%s","last_seen":"%s","count":%d}',
                $p->{pattern_hash}, $pattern_escaped, $sample_escaped, $p->{service}, $p->{level}, $p->{first_seen}, $p->{last_seen}, $p->{count});
        }
        my $json = '{"patterns":[' . join(',', @pattern_json) . '],"total":' . scalar(@$patterns) . '}';
        cache_set($cache_key, { raw_json => $json }, 30);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->res->headers->content_type('application/json');
        $c->render(data => $json);
    });

    $protected->get('/patterns/:hash/logs' => sub {
        my ($c) = @_;
        my $hash = $c->param('hash');
        return $c->render(json => { error => 'Invalid hash' }, status => 400) unless $hash && $hash =~ /^\d+$/;
        my $limit = $c->param('limit') // 100;
        my ($from, $to) = ($c->param('from'), $c->param('to'));
        ($from, $to) = parse_time_range($c->param('range')) if $c->param('range');
        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to} = $to if $to;
        my $result = $storage->get_pattern_logs($hash, %params);
        $c->render(json => { pattern_hash => $hash, hits => $result->{hits}, total => $result->{total} });
    });

    $protected->get('/patterns/stats' => sub {
        my ($c) = @_;
        my $cache_key = 'pattern_stats';
        if (my $cached = cache_get($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            return $c->render(json => $cached);
        }
        my $stats = $storage->get_pattern_stats();
        cache_set($cache_key, $stats, 60);
        $c->res->headers->header('X-Cache' => 'MISS');
        $c->render(json => $stats);
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Patterns - Log pattern analysis routes

=cut

package Purl::API::Routes::Logs;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(encode_json decode_json);
use Digest::MD5 qw(md5_hex);

our @EXPORT_OK = qw(setup_log_routes);

# ============================================
# Log Routes Setup
# ============================================

sub setup_log_routes {
    my ($protected, $storage, $metrics, $cache_funcs, $broadcast_func) = @_;

    my ($cache_get, $cache_set, $cache_clear) = @$cache_funcs;

    # Search logs (with caching)
    $protected->get('/logs' => sub {
        my ($c) = @_;
        my $query   = $c->param('q') // '';
        my $from    = $c->param('from');
        my $to      = $c->param('to');
        my $level   = $c->param('level');
        my $service = $c->param('service');
        my $host    = $c->param('host');
        my $limit   = $c->param('limit') // 500;
        my $offset  = $c->param('offset') // 0;
        my $order   = $c->param('order') // 'DESC';

        if (my $range = $c->param('range')) {
            ($from, $to) = _parse_time_range($range);
        }

        my %params = (
            limit  => int($limit),
            offset => int($offset),
            order  => $order,
        );

        $params{from}    = $from if $from;
        $params{to}      = $to if $to;
        $params{level}   = $level if $level;
        $params{service} = $service if $service;
        $params{host}    = $host if $host;

        # Parse KQL query
        if ($query) {
            if ($query =~ /^(\w+):(.+)$/) {
                my ($field, $value) = ($1, $2);
                $field = lc($field);
                $value =~ s/^["']|["']$//g;

                if ($field eq 'level') {
                    $params{level} = uc($value);
                } elsif ($field eq 'service') {
                    $params{service} = $value;
                } elsif ($field eq 'host') {
                    $params{host} = $value;
                } else {
                    $params{query} = $value;
                }
            } else {
                $params{query} = $query;
            }
        }

        # Check cache
        my $cache_key = md5_hex(encode_json(\%params));
        if (my $cached = $cache_get->($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $results = $storage->search(%params);
        my $total = $storage->count(%params);

        my $response = {
            hits  => $results,
            total => $total,
            query => $query,
        };

        # Cache results (shorter TTL for real-time data)
        $cache_set->($cache_key, $response, 10);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });

    # Ingest logs (POST)
    $protected->post('/logs' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $metrics->{errors_total}++;
            $c->render(json => { error => 'Invalid JSON' }, status => 400);
            return;
        }

        my $logs = ref $body eq 'ARRAY' ? $body : [$body];
        my $count = 0;

        for my $log (@$logs) {
            $log->{timestamp} //= _epoch_to_iso(time());
            $log->{level} //= 'INFO';
            $log->{service} //= 'unknown';
            $log->{host} //= 'unknown';
            $log->{message} //= $log->{msg} // $log->{log} // '';
            $log->{raw} //= $log->{message};
            $log->{meta} //= {};

            $storage->insert($log);
            $count++;
        }

        $storage->flush() if $storage->can('flush');

        $metrics->{logs_ingested} += $count;

        # Invalidate search cache on new data
        $cache_clear->();

        # Broadcast to WebSocket subscribers
        $broadcast_func->($logs) if $broadcast_func;

        $c->render(json => {
            status => 'ok',
            inserted => $count
        });
    });

    # KQL query endpoint (POST)
    $protected->post('/query' => sub {
        my ($c) = @_;
        my $body = decode_json($c->req->body);

        my $query = $body->{query} // '';
        my $from  = $body->{from};
        my $to    = $body->{to};
        my $limit = $body->{limit} // 500;

        my %params = (limit => int($limit));
        $params{from} = $from if $from;
        $params{to}   = $to if $to;

        if ($query) {
            $params{query} = $query;
        }

        my $results = $storage->search(%params);

        $c->render(json => {
            hits  => $results,
            total => scalar(@$results),
        });
    });
}

# ============================================
# Helper Functions
# ============================================

sub _parse_time_range {
    my ($range) = @_;

    my $now = time();
    my $from;

    if ($range =~ /^(\d+)m$/) {
        $from = $now - ($1 * 60);
    }
    elsif ($range =~ /^(\d+)h$/) {
        $from = $now - ($1 * 3600);
    }
    elsif ($range =~ /^(\d+)d$/) {
        $from = $now - ($1 * 86400);
    }
    else {
        return (undef, undef);
    }

    my $from_ts = _epoch_to_iso($from);
    my $to_ts = _epoch_to_iso($now);

    return ($from_ts, $to_ts);
}

sub _epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

1;

__END__

=head1 NAME

Purl::API::Routes::Logs - Log search and ingestion routes

=cut

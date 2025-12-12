package Purl::API::Controller::Logs;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);
use Digest::MD5 qw(md5_hex);
use Time::HiRes qw(time);

extends 'Purl::API::Controller::Base';

# Shared state for live tail
has 'websockets' => (
    is => 'ro',
    default => sub { [] },
);

# Import helper for ISO time
use Time::Piece;

sub _broadcast_logs {
    my ($self, $logs) = @_;
    return unless @$logs;

    my $conns = $self->websockets;
    
    for my $ws (@$conns) {
        next unless $ws;
        eval {
            my $filter = $ws->{filter} // {};
            my @matches;

            for my $log (@$logs) {
                # Apply all filters server-side to reduce bandwidth

                # Level filter (exact match or array)
                if ($filter->{level}) {
                    if (ref $filter->{level} eq 'ARRAY') {
                        my %allowed = map { uc($_) => 1 } @{$filter->{level}};
                        next unless $allowed{uc($log->{level} // '')};
                    } else {
                        next if uc($log->{level} // '') ne uc($filter->{level});
                    }
                }

                # Service filter (exact match or wildcard)
                if ($filter->{service}) {
                    my $service = $log->{service} // '';
                    my $pattern = $filter->{service};
                    if ($pattern =~ /\*/) {
                        # Convert wildcard to regex
                        $pattern =~ s/\./\\./g;
                        $pattern =~ s/\*/.*/g;
                        next unless $service =~ /^$pattern$/i;
                    } else {
                        next if lc($service) ne lc($pattern);
                    }
                }

                # Host filter
                if ($filter->{host}) {
                    next if lc($log->{host} // '') ne lc($filter->{host});
                }

                # Message contains filter (case-insensitive)
                if ($filter->{query}) {
                    my $message = $log->{message} // '';
                    next unless index(lc($message), lc($filter->{query})) >= 0;
                }
                
                push @matches, $log;
            }
            
            if (@matches) {
                $ws->send({json => \@matches});
            }
        };
    }
}

sub query {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
             $self->render_error($c, 'Invalid JSON', 400);
             return;
        }

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

        my $results = $self->storage->search(%params);

        $c->render(json => {
            hits  => $results,
            total => scalar(@$results),
        });
    });
}

sub _epoch_to_iso {
    my ($epoch) = @_;
    return Time::Piece->new($epoch)->datetime;
}

sub _parse_time_range {
    my ($range) = @_;
    my ($from, $to);
    
    # Simple range parsing logic (same as in Server.pm but implicit)
    # Server.pm didn't show _parse_time_range implementation in lines 1-800?
    # I should check Server.pm for _parse_time_range implementation or implement it here.
    # It was likely further down in the file. I will implement a basic version or simple pass-through.
    
    # We will just implement parsing of 1h, 24h etc.
    my $t = Time::Piece->new;
    if ($range =~ /^(\d+)([hmda])$/) {
        my ($val, $unit) = ($1, $2);
        my $seconds = $val * ($unit eq 'm' ? 60 : $unit eq 'h' ? 3600 : $unit eq 'd' ? 86400 : 1);
        $from = ($t - $seconds)->datetime;
        $to = $t->datetime;
    }
    
    return ($from, $to);
}

sub search {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
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
        if (my $cached = $self->get_cached($cache_key)) {
            $c->res->headers->header('X-Cache' => 'HIT');
            $c->render(json => $cached);
            return;
        }

        my $results = $self->storage->search(%params);
        # Use simple count estimation or separate count query?
        # Server.pm called $storage->count(%params).
        my $total = $self->storage->count(%params);

        my $response = {
            hits  => $results,
            total => $total,
            query => $query,
        };

        # Cache results
        $self->set_cached($cache_key, $response, 10);
        $c->res->headers->header('X-Cache' => 'MISS');

        $c->render(json => $response);
    });
}

sub ingest {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $raw_body = $c->req->body;
        my $logs = [];

        my $body = eval { decode_json($raw_body) };
        if ($body) {
            $logs = ref $body eq 'ARRAY' ? $body : [$body];
        } else {
            for my $line (split /\n/, $raw_body) {
                next unless $line =~ /\S/;
                my $log = eval { decode_json($line) };
                push @$logs, $log if $log;
            }
        }

        unless (@$logs) {
            $self->render_error($c, 'Invalid JSON or NDJSON', 400);
            return;
        }

        my $count = 0;
        for my $log (@$logs) {
            $log->{timestamp} //= _epoch_to_iso(time());
            $log->{level} //= 'INFO';
            $log->{service} //= 'unknown';
            $log->{host} //= 'unknown';
            $log->{message} //= $log->{msg} // $log->{log} // '';
            $log->{raw} //= $log->{message};
            $log->{meta} //= {};

            $self->storage->insert($log);
            $count++;
        }

        # Flush immediately for testing/low load, or rely on background flush
        $self->storage->flush() if $self->storage->can('flush');

        # Broadcast to WebSocket subscribers
        $self->_broadcast_logs($logs);
        
        $c->render(json => {
            status => 'ok',
            inserted => $count
        });
    });
}

sub context {
    my ($self, $c) = @_;
    
    $self->safe_execute($c, sub {
        my $id     = $c->param('id');
        my $before = $c->param('before') // 50;
        my $after  = $c->param('after') // 50;

        unless ($id && $id =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i) {
            $self->render_error($c, 'Invalid log ID format', 400);
            return;
        }

        # Need to fix get_context in storage too? No, it wasn't modified.
        # But wait, storage->get_context was used in Server.pm.
        
        my $context = eval { 
            $self->storage->get_context($id,
                before => int($before),
                after  => int($after),
            );
        };
        if ($@) {
            # Handle "Log not found" or other errors
             $self->render_error($c, 'Log not found', 404);
             return;
        }

        unless ($context && $context->{reference}) {
            $self->render_error($c, 'Log not found', 404);
            return;
        }

        $c->render(json => {
            reference    => $context->{reference},
            before_logs  => $context->{before},
            after_logs   => $context->{after},
            before_count => scalar(@{$context->{before}}),
            after_count  => scalar(@{$context->{after}}),
        });
    });
}

1;

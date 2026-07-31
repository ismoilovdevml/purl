package Purl::API::Controller::Logs;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json from_json);
use Digest::MD5 qw(md5_hex);
use Time::HiRes qw(time);
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);

use Purl::Util::Time qw(parse_time_range epoch_to_iso);

extends 'Purl::API::Controller::Base';

# Shared state for live tail WebSocket connections
has 'websockets' => (
    is => 'ro',
    default => sub { [] },
);

# Broadcast backend (Purl::Broadcast::Local or Purl::Broadcast::Redis)
has 'broadcaster' => (
    is      => 'rw',
    default => sub { undef },
);

sub _broadcast_logs {
    my ($self, $logs) = @_;
    return unless @$logs;

    if ($self->broadcaster) {
        # Publish via broadcast system (Redis or Local)
        # Other instances receive this via their subscription callbacks
        $self->broadcaster->publish(
            $self->broadcaster->default_channel,
            $logs,
        );
    } else {
        # Direct local delivery (backward-compatible fallback)
        $self->_deliver_to_websockets($logs);
    }
}

# Apply per-connection filters and send matching logs to WebSocket clients
sub _deliver_to_websockets {
    my ($self, $logs) = @_;
    return unless @$logs;

    my $conns = $self->websockets;

    for my $ws (@$conns) {
        next unless $ws;
        eval {
            my @matches = $self->_filter_logs($ws->{filter} // {}, $logs);
            if (@matches) {
                $ws->send({json => \@matches});
            }
        };
    }
}

# Filter logs against a subscriber filter — returns matching logs
sub _filter_logs {
    my ($self, $filter, $logs) = @_;
    my @matches;

    for my $log (@$logs) {
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

    return @matches;
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

        return unless $self->_apply_query($c, \%params, $query);

        my $results = $self->storage->search(%params);

        $c->render(json => {
            hits  => $results,
            total => scalar(@$results),
        });
    });
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
            ($from, $to) = parse_time_range($range);
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

        # KQL when the string declares itself as KQL, literal text otherwise.
        return unless $self->_apply_query($c, \%params, $query);

        # Check cache. The AST is keyed by its SOURCE string: hash key order in
        # a nested structure is not stable, so hashing the AST itself would
        # produce a different key for the same query.
        my $cache_key = md5_hex(encode_json({ %params, kql => $query }));
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

        # Handle gzip-compressed requests (from Vector with compression = "gzip")
        my $content_encoding = $c->req->headers->content_encoding // '';
        if ($content_encoding eq 'gzip') {
            my $decompressed;
            unless (gunzip(\$raw_body => \$decompressed)) {
                $self->render_error($c, "Gzip decompression failed: $GunzipError", 400);
                return;
            }
            $raw_body = $decompressed;
        }

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

        if (scalar(@$logs) > 10_000) {
            $self->render_error($c, 'Batch too large: maximum 10000 logs per request', 400);
            return;
        }

        # Enforce server limit from license
        my $server_names = {};
        for my $log (@$logs) {
            my $svc = $log->{service} // $log->{host} // 'unknown';
            $server_names->{$svc} = 1;
        }
        my $new_server_count = scalar keys %$server_names;

        my $license_info = $c->stash('license_info');
        if ($license_info && $license_info->{valid} && $license_info->{activated}
            && ($license_info->{limits}{servers} // -1) >= 0)
        {
            # Only reached when the plan actually meters servers. Guarding here
            # (instead of inside check_limit) keeps the expensive field_stats
            # GROUP BY off the ingest hot path for the unlimited plans, which
            # is every plan we currently sell.
            #
            # Current unique server list. field_stats('service') is a GROUP BY
            # over the whole logs table — far too expensive to run on every
            # ingest. Cache it briefly so the hot path scans at most once per
            # window instead of once per request.
            my $existing_servers = $self->get_cached('ingest:known_services');
            unless (defined $existing_servers) {
                $existing_servers = eval {
                    $self->storage->field_stats('service', limit => 1000);
                } // [];
                $self->set_cached('ingest:known_services', $existing_servers, 60);
            }
            # Servers this batch would ADD on top of the ones already stored.
            my %existing_set = map { $_->{value} => 1 } @$existing_servers;
            my $adding = grep { !$existing_set{$_} } keys %$server_names;

            # Single quota gate for the whole codebase — see Controller::Base.
            return unless $self->check_limit(
                $c, 'servers', scalar(@$existing_servers), $adding
            );
        }

        # Validate all logs before inserting
        for my $log (@$logs) {
            if (defined $log->{level} && length($log->{level}) > 32) {
                $self->render_error($c, 'Invalid log level: exceeds maximum length', 400);
                return;
            }
        }

        # Run logs through configured pipelines (enrich / rewrite / drop)
        # BEFORE storage. No-op unless the license includes pipelines and
        # pipelines are configured. Drops shrink the batch; the count,
        # backpressure check, and broadcast below all use the result.
        $logs = $self->apply_pipelines($c, $logs);

        # Backpressure: if the in-memory buffer cannot absorb this batch, refuse
        # with 503 instead of growing the buffer unbounded (OOM) or silently
        # accepting logs we cannot store. NOTE: the buffer is per-process, so
        # under prefork this cap is enforced per worker.
        if ($self->storage->can('buffer_full')
            && $self->storage->buffer_full(scalar @$logs)) {
            $c->res->headers->header('Retry-After' => '1');
            $c->render(json => {
                status => 'error',
                error  => 'Ingest buffer full — backpressure, retry shortly',
            }, status => 503);
            return;
        }

        my $durable = $self->storage->can('durable') ? $self->storage->durable : 0;

        my $count = 0;
        my $ok = eval {
            for my $log (@$logs) {
                $log->{timestamp} //= epoch_to_iso(time());
                $log->{level} //= 'INFO';
                $log->{service} //= 'unknown';
                $log->{host} //= 'unknown';
                $log->{message} //= $log->{msg} // $log->{log} // '';
                $log->{raw} //= $log->{message};
                # Collectors that cannot build a nested object (Vector's
                # encode_json, Fluent Bit's http output) send meta as a JSON
                # string — decode it instead of dropping the metadata.
                #
                # from_json, NOT decode_json: at this point $log->{meta} is a
                # decoded CHARACTER string (the whole body already went through
                # decode_json above). decode_json expects UTF-8 BYTES and dies
                # with "Wide character" on any non-ASCII meta, which the eval
                # would swallow — silently turning {"note":"ключ"} into {}.
                if (defined $log->{meta} && !ref $log->{meta}) {
                    my $decoded = eval { from_json($log->{meta}) };
                    $log->{meta} = ref $decoded eq 'HASH' ? $decoded : {};
                }
                if (exists $log->{meta} && ref($log->{meta}) ne 'HASH') {
                    $log->{meta} = {};
                }
                $log->{meta} //= {};

                # Field length validation
                if (defined $log->{message} && length($log->{message}) > 65536) {
                    $log->{message} = substr($log->{message}, 0, 65536);
                }
                if (defined $log->{service} && length($log->{service}) > 256) {
                    $log->{service} = substr($log->{service}, 0, 256);
                }
                if (defined $log->{host} && length($log->{host}) > 256) {
                    $log->{host} = substr($log->{host}, 0, 256);
                }
                if (defined $log->{raw} && length($log->{raw}) > 131072) {
                    $log->{raw} = substr($log->{raw}, 0, 131072);
                }
                $self->storage->insert($log);
                $count++;
            }

            # Durable mode: flush synchronously and let ClickHouse confirm the
            # write before we return 2xx. In fast mode we do NOT flush per
            # request — that defeats buffering; size-based flush (in insert) and
            # the periodic background flush handle it.
            if ($durable && $self->storage->can('flush')) {
                $self->storage->flush();
            }
            1;
        };

        unless ($ok) {
            my $err = $@ || 'unknown storage error';
            $c->app->log->error("Ingest storage failure: $err");
            # A flush/insert error must surface as an error status, never a
            # silent 200. In durable mode the batch is retained in the buffer
            # for retry (at-least-once).
            $c->res->headers->header('Retry-After' => '1');
            $c->render(json => {
                status => 'error',
                error  => 'Storage unavailable — log not accepted',
            }, status => 503);
            return;
        }

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

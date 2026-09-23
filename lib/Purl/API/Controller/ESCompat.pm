package Purl::API::Controller::ESCompat;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

extends 'Purl::API::Controller::Base';

# ============================================
# Elasticsearch-compatible search API
# Translates basic ES query DSL to ClickHouse
# ============================================

sub search {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $size   = $body->{size}   // 10;
        my $from   = $body->{from}   // 0;
        my $sort   = $body->{sort}   // [{ timestamp => { order => 'desc' } }];
        my $query  = $body->{query}  // { match_all => {} };

        # Validate limits
        $size = 10000 if $size > 10000;
        $from = 0     if $from < 0;

        # Translate ES query to search params
        my %params = (
            limit  => $size,
            offset => $from,
        );

        # Parse sort
        if (ref $sort eq 'ARRAY' && @$sort) {
            my $first = $sort->[0];
            if (ref $first eq 'HASH') {
                my ($field) = keys %$first;
                if ($field eq 'timestamp' || $field eq '@timestamp') {
                    my $dir = $first->{$field}{order} // 'desc';
                    $params{order} = $dir eq 'asc' ? 'ASC' : 'DESC';
                }
            }
        }

        # Translate query
        my @conditions = _translate_query($query);
        $params{query} = join(' ', @conditions) if @conditions;

        # Extract time range from query
        _extract_time_range($query, \%params);

        my $results = $self->storage->search(%params);
        my $total   = $self->storage->count(%params);

        # Build ES-compatible response
        my @hits;
        for my $row (@$results) {
            push @hits, {
                _index  => 'purl-logs',
                _id     => $row->{id},
                _source => {
                    '@timestamp' => $row->{timestamp},
                    level        => $row->{level},
                    service      => $row->{service},
                    host         => $row->{host},
                    message      => $row->{message},
                    meta         => $row->{meta},
                },
            };
        }

        $c->render(json => {
            took      => 0,
            timed_out => \0,
            hits      => {
                total => { value => $total, relation => 'eq' },
                hits  => \@hits,
            },
        });
    });
}

sub msearch {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body_text = $c->req->body;
        unless ($body_text) {
            $self->render_error($c, 'Empty request body', 400);
            return;
        }

        my @lines = split /\n/, $body_text;
        my @responses;

        # NDJSON: pairs of (header, body)
        while (@lines >= 2) {
            my $header_line = shift @lines;
            my $body_line   = shift @lines;

            next unless $header_line =~ /\S/ && $body_line =~ /\S/;

            my $search_body = eval { decode_json($body_line) };
            next unless $search_body;

            my $size  = $search_body->{size}  // 10;
            my $query = $search_body->{query} // { match_all => {} };

            my %params = (limit => $size);
            my @conditions = _translate_query($query);
            $params{query} = join(' ', @conditions) if @conditions;
            _extract_time_range($query, \%params);

            my $results = $self->storage->search(%params);
            my $total   = $self->storage->count(%params);

            my @hits;
            for my $row (@$results) {
                push @hits, {
                    _index  => 'purl-logs',
                    _id     => $row->{id},
                    _source => {
                        '@timestamp' => $row->{timestamp},
                        level        => $row->{level},
                        service      => $row->{service},
                        host         => $row->{host},
                        message      => $row->{message},
                    },
                };
            }

            push @responses, {
                took      => 0,
                timed_out => \0,
                hits      => {
                    total => { value => $total, relation => 'eq' },
                    hits  => \@hits,
                },
            };
        }

        $c->render(json => { responses => \@responses });
    });
}

sub field_caps {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        $c->render(json => {
            indices => ['purl-logs'],
            fields  => {
                '@timestamp' => { date     => { type => 'date',    searchable => \1, aggregatable => \1 } },
                message      => { text     => { type => 'text',    searchable => \1, aggregatable => \0 } },
                level        => { keyword  => { type => 'keyword', searchable => \1, aggregatable => \1 } },
                service      => { keyword  => { type => 'keyword', searchable => \1, aggregatable => \1 } },
                host         => { keyword  => { type => 'keyword', searchable => \1, aggregatable => \1 } },
                trace_id     => { keyword  => { type => 'keyword', searchable => \1, aggregatable => \1 } },
                request_id   => { keyword  => { type => 'keyword', searchable => \1, aggregatable => \1 } },
            },
        });
    });
}

# ============================================
# Query DSL translation helpers
# ============================================

sub _translate_query {
    my ($query) = @_;
    return () unless $query && ref $query eq 'HASH';

    # match_all
    return () if exists $query->{match_all};

    # query_string
    if (my $qs = $query->{query_string}) {
        my $q = $qs->{query} // '';
        return ($q) if $q;
    }

    # match on a specific field
    if (my $match = $query->{match}) {
        my @parts;
        for my $field (keys %$match) {
            my $val = ref $match->{$field} eq 'HASH' ? $match->{$field}{query} : $match->{$field};
            push @parts, $val if defined $val;
        }
        return @parts;
    }

    # multi_match
    if (my $mm = $query->{multi_match}) {
        return ($mm->{query}) if $mm->{query};
    }

    # bool
    if (my $bool = $query->{bool}) {
        my @parts;
        for my $clause (@{ $bool->{must} // [] }) {
            push @parts, _translate_query($clause);
        }
        for my $clause (@{ $bool->{should} // [] }) {
            push @parts, _translate_query($clause);
        }
        return @parts;
    }

    # term
    if (my $term = $query->{term}) {
        my @parts;
        for my $field (keys %$term) {
            my $val = ref $term->{$field} eq 'HASH' ? $term->{$field}{value} : $term->{$field};
            push @parts, $val if defined $val;
        }
        return @parts;
    }

    return ();
}

sub _extract_time_range {
    my ($query, $params) = @_;
    return unless $query && ref $query eq 'HASH';

    # Direct range query
    if (my $range = $query->{range}) {
        _apply_range($range, $params);
        return;
    }

    # Nested in bool.filter or bool.must
    if (my $bool = $query->{bool}) {
        for my $clause (@{ $bool->{filter} // [] }, @{ $bool->{must} // [] }) {
            if ($clause && ref $clause eq 'HASH' && $clause->{range}) {
                _apply_range($clause->{range}, $params);
            }
        }
    }
}

sub _apply_range {
    my ($range, $params) = @_;
    for my $field (keys %$range) {
        next unless $field eq 'timestamp' || $field eq '@timestamp';
        my $spec = $range->{$field};
        $params->{from} = $spec->{gte} // $spec->{gt} if $spec->{gte} // $spec->{gt};
        $params->{to}   = $spec->{lte} // $spec->{lt} if $spec->{lte} // $spec->{lt};
    }
}

1;

__END__

=head1 NAME

Purl::API::Controller::ESCompat - Elasticsearch-compatible search API

=head1 DESCRIPTION

Provides basic Elasticsearch-compatible endpoints for tools that speak
ES query DSL (Kibana, Grafana, etc.). Translates queries to ClickHouse.

Endpoints:
    POST /es/_search       - Search logs
    POST /es/_msearch      - Multi-search
    GET  /es/_field_caps   - Field capabilities

=cut

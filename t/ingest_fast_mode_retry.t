#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Storage::ClickHouse;
use Purl::Metrics::Counters;
use Purl::Metrics::Prometheus;

# ============================================
# #115 — in fast mode (ingest.durable=0, the default) POST /api/logs answers
# 200 when the log enters the buffer; a failed flush then threw the batch away.
# The contract now: a failed flush keeps the batch for retry in both modes,
# the buffer stays bounded by buffer_max (ingest answers 503 when it is full),
# and anything that ever has to be dropped is counted and logged.
#
# Storage is real Purl::Storage::ClickHouse; only its HTTP client is replaced so
# ClickHouse can be made to fail on demand. (t/ingest_outage_clickhouse.t does
# the same against a real ClickHouse behind a proxy that is cut mid-stream.)
# ============================================

{
    package FakeHTTP;
    sub new { bless { fail => 0, bodies => [], calls => 0 }, shift }
    sub post {
        my ($self, $url, $args) = @_;
        $self->{calls}++;
        return { success => 0, status => 500,
                 content => 'Code: 241. DB::Exception: Memory limit exceeded' } if $self->{fail};
        push @{ $self->{bodies} }, $args->{content};
        return { success => 1, status => 200, content => '' };
    }
    sub rows { my $n = 0; $n += () = $_ =~ /\{/g for @{ $_[0]{bodies} }; $n }
    sub messages { [ map { /"message":"([^"]*)"/g } @{ $_[0]{bodies} } ] }
}

{   # no schema/DDL: this test is about the buffer, not ClickHouse
    no warnings 'redefine';
    *Purl::Storage::ClickHouse::_init_schema = sub { 1 };
}

sub new_storage {
    my (%o) = @_;
    my $http = FakeHTTP->new;
    my $st = Purl::Storage::ClickHouse->new(
        durable => 0, buffer_size => 1000, buffer_max => 100, flush_interval => 0,
        %o, _http => $http,
    );
    return ($st, $http);
}

sub logs { my ($p, $n) = @_; [ map { { level => 'info', message => "$p-$_" } } 1 .. $n ] }

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

subtest 'fast mode: failed flush keeps the batch, the next flush delivers it' => sub {
    my ($st, $http) = new_storage();
    $st->insert_batch(logs('a', 5));
    $http->{fail} = 1;

    ok !eval { $st->flush; 1 }, 'flush reports the ClickHouse failure';
    is $st->buffer_depth, 5, 'all 5 rows are still buffered (were dropped before #115)';

    $st->insert_batch(logs('b', 3));
    $http->{fail} = 0;
    is $st->flush, 8, 'retry flush writes the kept rows plus the new ones';
    is_deeply $http->messages, [ (map {"a-$_"} 1 .. 5), (map {"b-$_"} 1 .. 3) ],
        'delivered once each, oldest first';
    is $st->buffer_depth, 0, 'buffer empty after the successful retry';
    is $st->_metrics->{ingest_dropped_total} // 0, 0, 'nothing dropped';
};

subtest 'fast mode: size-triggered flush failure does not fail the insert' => sub {
    my ($st, $http) = new_storage(buffer_size => 4);
    $http->{fail} = 1;
    my $ok = eval { $st->insert_batch(logs('c', 4)); 1 };
    ok $ok, 'insert_batch does not die: the rows are held for retry';
    is $st->buffer_depth, 4, 'rows kept';

    # While failing, the size trigger backs off instead of retrying per row.
    my ($st2, $http2) = new_storage(buffer_size => 2, flush_interval => 60);
    $http2->{fail} = 1;
    $st2->insert({ message => "d-$_" }) for 1 .. 20;
    is $http2->{calls}, 1, 'one attempt, not one per inserted row, while ClickHouse fails';
    is $st2->buffer_depth, 20, 'every row kept';
};

subtest 'durable mode: failure still propagates and keeps the batch' => sub {
    my ($st, $http) = new_storage(durable => 1);
    $st->insert_batch(logs('e', 2));
    $http->{fail} = 1;
    ok !eval { $st->flush; 1 }, 'flush dies';
    is $st->buffer_depth, 2, 'batch kept';
};

subtest 'bounded: overflow drops the OLDEST rows, counted and reported' => sub {
    my ($st, $http) = new_storage(buffer_max => 10);
    my @hook;
    $st->on_ingest_drop(sub { push @hook, [@_] });
    $http->{fail} = 1;
    $st->insert_batch(logs('f', 8));
    ok $st->buffer_full(3), 'buffer_full(3) tells ingest to answer 503 at this depth';

    # A caller that ignored buffer_full:
    $st->insert_batch(logs('g', 5));
    is $st->buffer_depth, 10, 'buffer never exceeds buffer_max';
    is $st->_metrics->{ingest_dropped_total}, 3, 'three rows counted as dropped';
    is scalar @hook, 1, 'drop hook called once';
    is $hook[0][0], 3, 'hook got the count';

    $http->{fail} = 0;
    $st->flush;
    is_deeply $http->messages, [ (map {"f-$_"} 4 .. 8), (map {"g-$_"} 1 .. 5) ],
        'the newest 10 rows were kept, the 3 oldest dropped';
};

subtest 'drop without a hook is logged, never silent' => sub {
    @warnings = ();
    my ($st) = new_storage(buffer_max => 2);
    $st->insert_batch(logs('h', 3));
    like join('', @warnings), qr/Ingest DROPPED 1 log/, 'warning names the drop';
};

subtest 'purl_ingest_dropped_total is exported' => sub {
    require Purl::Store::Counter;
    my $counters = Purl::Metrics::Counters->new(store => Purl::Store::Counter->new);
    my $text = Purl::Metrics::Prometheus::render(counters => $counters->snapshot);
    like $text, qr/^purl_ingest_dropped_total 0$/m, 'present at 0 before any drop';

    $counters->record_ingest_dropped(7);
    $text = Purl::Metrics::Prometheus::render(counters => $counters->snapshot);
    like $text, qr/^purl_ingest_dropped_total 7$/m, 'counts drops';
    like $text, qr/^# TYPE purl_ingest_dropped_total counter$/m, 'typed as a counter';
};

subtest 'PURL_INGEST_DURABLE is read as a boolean' => sub {
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    local $ENV{PURL_CONFIG_DIR}  = $dir;
    local $ENV{PURL_CONFIG_FILE} = "$dir/settings.json";
    for my $case ([1, 1], [0, 0], ['true', 1], ['false', 0], ['off', 0], ['yes', 1]) {
        local $ENV{PURL_INGEST_DURABLE} = $case->[0];
        my $st = Purl::Storage::ClickHouse->new(_http => FakeHTTP->new);
        is $st->durable, $case->[1], "PURL_INGEST_DURABLE=$case->[0] => durable $case->[1]";
    }
};

done_testing;

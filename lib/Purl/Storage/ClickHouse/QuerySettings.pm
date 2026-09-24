package Purl::Storage::ClickHouse::QuerySettings;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# The ClickHouse settings every statement is sent with: async-insert mode,
# execution/row limits, the per-query memory guard and version-dependent
# optimisations. Connection puts them on the URL; nothing else builds them.
# ============================================

# Async-insert settings, applied consistently everywhere an INSERT is issued.
# durable=1 => wait_for_async_insert=1 (HTTP returns only once the row is
# persisted). durable=0 => legacy fire-and-forget fast path.
sub _async_insert_settings {
    my ($self) = @_;
    my $wait = $self->durable ? 1 : 0;
    return "async_insert=1&wait_for_async_insert=$wait";
}

# ClickHouse performance settings.
#
# sync => 1 makes the statement read-after-write consistent:
#   async_insert=0   — the INSERT is not parked in ClickHouse's async buffer
#   mutations_sync=1 — ALTER ... UPDATE/DELETE is applied before we return
#
# Log ingest batches thousands of rows/s and trades visibility latency for
# throughput. CRUD statements (alerts, saved searches, dashboards, pipelines,
# agents) write one row at a time and are read back immediately by the UI, so
# for them the async buffer and background mutations are pure downside: the row
# is invisible — or a deleted row still visible — for seconds after a 200 OK.
sub _query_settings {
    my ($self, %opts) = @_;
    my @settings = (
        'max_execution_time=' . $self->max_execution_time,
        'max_rows_to_read=' . $self->max_rows_to_read,
        'optimize_read_in_order=1',
        $self->_memory_settings,
        $self->_optional_settings,
        'load_balancing=nearest_hostname',
        'prefer_localhost_replica=1',
        $opts{sync} ? 'async_insert=0&mutations_sync=1' : $self->_async_insert_settings,
    );
    return join('&', @settings);
}

# Per-query memory guard (#108). No single statement may take more than
# max_query_memory: a sort or GROUP BY that grows past a quarter of it spills to
# disk, and anything still larger fails ALONE with MEMORY_LIMIT_EXCEEDED
# instead of pushing the whole server over its limit (on a production cluster one
# unbounded search did exactly that and every query, ingest included, failed).
# 0 disables the guard (the server profile then decides).
sub _memory_settings {
    my ($self) = @_;
    my $max = $self->max_query_memory or return ();
    my $spill = int($max / 4);
    return (
        "max_memory_usage=$max",
        "max_bytes_before_external_sort=$spill",
        "max_bytes_before_external_group_by=$spill",
    );
}

# Settings sent only when the server knows them: an unknown setting in the URL
# fails the whole query, and Purl also runs against external ClickHouse servers
# older than the one docker-compose ships.
#
#   query_plan_max_limit_for_lazy_materialization (ClickHouse 25.x)
#     ORDER BY ... LIMIT n reads the wide columns (message, raw, meta) only for
#     the n rows that survive the sort, if n <= this value. The default is 100;
#     the Logs page asks for 500-2000. Measured on 25.11 with 4M rows (1h):
#     p50 595 ms -> 37 ms, 166 MiB -> 9 MiB, 2.09 GiB read -> 63 MiB.
my %OPTIONAL_SETTINGS = (
    query_plan_max_limit_for_lazy_materialization => 10000,
);

# Probed once per PROCESS with the first query that needs it, and re-probed
# until it succeeds: a server that was down at startup must not lose these
# settings for the life of the worker. The result is keyed by pid so a probe
# made before prefork's fork (schema init) is not inherited by the workers —
# each worker asks the server itself.
has '_supported_optional_settings' => (is => 'rw');

# After a failed probe, wait this long before the next one: during an outage a
# probe per query would double every round-trip to a server that is down.
has '_optional_probe_retry_at' => (is => 'rw', default => 0);
my $PROBE_RETRY_SECONDS = 30;

sub _optional_settings {
    my ($self) = @_;
    my $cached = $self->_supported_optional_settings;
    my $known  = $cached && $cached->{pid} == $$ ? $cached->{names} : undef;
    unless ($known) {
        return () if time() < $self->_optional_probe_retry_at;
        my $names = join ', ', map { "'$_'" } sort keys %OPTIONAL_SETTINGS;
        my $out = eval {
            $self->_query("SELECT name FROM system.settings WHERE name IN ($names)", no_settings => 1);
        };
        unless (defined $out) {
            $self->_optional_probe_retry_at(time() + $PROBE_RETRY_SECONDS);
            return ();
        }
        $known = { map { $_ => 1 } grep { length } split /\n/, $out };
        $self->_supported_optional_settings({ pid => $$, names => $known });
    }
    return map { "$_=$OPTIONAL_SETTINGS{$_}" } grep { $known->{$_} } sort keys %OPTIONAL_SETTINGS;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::QuerySettings - per-statement ClickHouse settings
(async insert, limits, memory guard, optional version-dependent settings).

=cut

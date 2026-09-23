package Purl::Storage::ClickHouse::K8sColumns;
use strict;
use warnings;
use 5.024;

use Moo::Role;
use namespace::clean;

# ============================================
# Kubernetes metadata as real columns (#104)
# ============================================
#
# The chart's Vector DaemonSet (and any shipper following the same contract)
# sends namespace/pod/container inside `meta`, a JSON string. Filtering or
# faceting on them used to mean parsing that JSON for every row in range.
#
# Measured on ClickHouse 25.11 with 1M k8s-shaped rows (30 namespaces, 26k
# pods), median of 7 runs:
#
#   facet namespace   JSONExtractString(meta)  46 ms   column  6 ms
#   facet pod         JSONExtractString(meta)  51 ms   column  9 ms
#   filter namespace  JSONExtractString(meta)  28 ms   column  4 ms
#
# at a storage cost of ~1 MiB per million rows for all three (meta: 7 MiB).
#
# So they are MATERIALIZED columns: computed from `meta` at insert time, never
# sent by the ingest path, and invisible to `SELECT *` (backups are unchanged).

# Column names double as the search-language field names (Purl::Util::KQL).
my @COLUMNS = qw(namespace pod container);

sub is_k8s_column {
    my ($self, $name) = @_;
    return (defined $name && grep { $_ eq $name } @COLUMNS) ? 1 : 0;
}

# SQL that reads one top-level key out of `meta` as a string.
#
# $key_sql is an SQL expression — a quoted literal in DDL, a bind placeholder
# in queries — never raw user input.
#
# Rows written by Purl versions that did not yet decode string meta hold a JSON
# string whose content is the JSON object (`"{\"pod\":\"x\"}"`); the inner
# JSONExtractString unwraps that first, so those rows are not silently blank.
sub meta_key_sql {
    my ($self, $key_sql) = @_;
    return "JSONExtractString(if(startsWith(meta, '\"'), JSONExtractString(meta), meta), $key_sql)";
}

# Add any missing k8s column to an existing logs table and backfill it.
#
# ADD COLUMN ... MATERIALIZED is metadata-only and instant; old parts compute
# the value on read until the MATERIALIZE COLUMN mutation has rewritten them.
# That mutation is issued ONLY for columns this call actually added, so a
# restart never queues another full-table rewrite. It runs in the background
# (mutations_sync=0): startup does not wait for it, and a failure to queue it
# only costs speed on old parts, so it warns instead of dying.
sub _ensure_k8s_columns {
    my ($self, $table) = @_;

    my $present = $self->_query_json(q{
        SELECT name FROM system.columns
        WHERE database = {p_db:String} AND table = {p_table:String}
    }, params => { p_db => $self->database, p_table => $self->table }, no_cache => 1);
    my %have = map { $_->{name} => 1 } @$present;

    my @added = grep { !$have{$_} } @COLUMNS;
    return [] unless @added;

    for my $col (@added) {
        my $expr = $self->meta_key_sql("'$col'");
        $self->_query("ALTER TABLE $table ADD COLUMN IF NOT EXISTS $col LowCardinality(String) MATERIALIZED $expr");
    }

    my $materialize = join ', ', map { "MATERIALIZE COLUMN $_" } @added;
    eval {
        $self->_query("ALTER TABLE $table $materialize SETTINGS mutations_sync = 0");
        1;
    } or warn "Purl: k8s column backfill not queued (@added): $@";

    return \@added;
}

1;

__END__

=head1 NAME

Purl::Storage::ClickHouse::K8sColumns - namespace/pod/container as MATERIALIZED
columns of the logs table, their one-time migration, and the shared SQL for
reading a key out of the C<meta> JSON.

=cut

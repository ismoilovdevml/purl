#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);
use Purl::Storage::ClickHouse;

# ============================================
# Restore must stay inside a per-query memory cap (#108 profile: 256 MiB per
# query, 1.5 GiB pod). Parallel CSV parsing of a large backup file allocated
# far past both (Code 241 in ParallelParsingBlockInputFormat, reproduced on
# ClickHouse 25.11 with a 3M-row / 638 MB CSV). Single-threaded parsing and
# bounded insert blocks restore the same file within the cap.
# ============================================

my @posts;
{
    no warnings 'redefine';
    *Purl::Storage::ClickHouse::_init_schema = sub { 1 };
    *Purl::Storage::ClickHouse::_query       = sub { '' };
    *Purl::Storage::ClickHouse::get_backup   = sub { { id => 'b1', status => 'completed' } };
    *Purl::Storage::ClickHouse::_post_file   = sub {
        my ($self, $sql, $file, %opts) = @_;
        push @posts, { sql => $sql, settings => $opts{settings} // '' };
        return { headers => { 'x-clickhouse-summary' => '{"written_rows":"2"}' } };
    };
}

my $dir = tempdir(CLEANUP => 1);
open my $fh, '>', "$dir/logs.csv" or die $!;
print {$fh} qq{"timestamp","message"\n"2026-09-23 18:00:00","a"\n"2026-09-23 18:00:01","b"\n};
close $fh;
{
    no warnings 'redefine';
    *Purl::Storage::ClickHouse::_materialize_backup_dir = sub { return ($dir, undef) };
}

my $st = Purl::Storage::ClickHouse->new;
eval { $st->restore_backup('b1'); 1 } or diag "restore died: $@";

is scalar @posts, 1, 'one INSERT for the one table file present';
my %s = map { split /=/, $_, 2 } split /&/, $posts[0]{settings} // '';

is $s{input_format_parallel_parsing}, 0,        'parallel parsing off';
is $s{max_insert_block_size},         65536,    'max_insert_block_size bounded';
is $s{min_insert_block_size_rows},    65536,    'min_insert_block_size_rows bounded';
is $s{min_insert_block_size_bytes},   67108864, 'min_insert_block_size_bytes bounded (64 MiB)';
ok defined $s{max_execution_time},              'the backup timeout is still sent';
is $s{max_rows_to_read},              0,        'the row cap is still lifted';

# Export keeps its own settings: bounded insert settings are restore-only.
unlike $st->_backup_query_settings, qr/input_format_parallel_parsing/, 'export settings unchanged';

done_testing;

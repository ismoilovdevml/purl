#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Purl::Util::TarStream qw(write_tar_gz extract_tar_gz);

# ============================================
# REGRESSION (#21): the tar step must not be RAM-bound.
#
# Export already streamed the ClickHouse response to disk and restore already
# streamed the CSV into the request body, but the tar step in between undid
# both: Archive::Tar::add_data takes the WHOLE member as a scalar, and
# get_content hands the WHOLE member back. So downloading or restoring a backup
# whose logs.csv is multi-GB OOM-killed the worker anyway.
#
# What is pinned here is not "uses less memory" but a NUMBER: no single buffer
# of member data exceeds the 64 KiB chunk, in either direction, for a 64 MiB
# archive. Both probes below fail loudly if anyone reintroduces a slurp.
# ============================================

my $dir = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "Cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# ============================================
# Round trip
# ============================================
subtest 'round trip preserves names and bytes' => sub {
    my $src = File::Spec->catdir($dir, 'rt_src');
    my $out = File::Spec->catdir($dir, 'rt_out');
    mkdir $src; mkdir $out;

    my %content = (
        'logs.csv'          => "ts,msg\n1,hello\n2,\"multi\nline\"\n",
        'alerts.csv'        => "id,name\n7,disk\n",
        'saved_searches.csv' => '',
    );
    write_file(File::Spec->catfile($src, $_), $content{$_}) for keys %content;

    my $archive = File::Spec->catfile($dir, 'rt.tar.gz');
    write_tar_gz($archive, [ map { { name => $_, path => File::Spec->catfile($src, $_) } }
                             sort keys %content ]);

    ok -s $archive, 'archive written';

    my $names = extract_tar_gz($archive, $out);
    is_deeply [sort @$names], [sort keys %content], 'every member extracted';

    for my $name (sort keys %content) {
        is slurp(File::Spec->catfile($out, $name)), $content{$name},
            "$name byte-identical after round trip";
    }
};

# ============================================
# Format compatibility — BOTH directions.
#
# Archives written before this change must still extract, and archives written
# now must still be readable by ordinary tar. ustar is the contract; a
# home-grown reader/writer pair that only talks to itself would strand every
# existing backup.
# ============================================
subtest 'Archive::Tar can read what write_tar_gz produced' => sub {
    require Archive::Tar;

    my $src = File::Spec->catdir($dir, 'compat_src');
    mkdir $src;
    my $body = "a,b\n" . ("1,2\n" x 5000);       # ~20 KB, spans no block boundary neatly
    write_file(File::Spec->catfile($src, 'logs.csv'), $body);

    my $archive = File::Spec->catfile($dir, 'compat_ours.tar.gz');
    write_tar_gz($archive, [ { name => 'logs.csv', path => File::Spec->catfile($src, 'logs.csv') } ]);

    my $tar = Archive::Tar->new();
    ok $tar->read($archive), 'Archive::Tar accepts our archive'
        or diag Archive::Tar->error;

    my @files = $tar->get_files;
    is scalar(@files), 1, 'one member';
    is $files[0]->name, 'logs.csv', 'name preserved';
    is $files[0]->size, length($body), 'size preserved';
    is $files[0]->get_content, $body, 'content preserved';
    ok $files[0]->is_file, 'typeflag says regular file';
};

subtest 'extract_tar_gz can read what Archive::Tar produced' => sub {
    require Archive::Tar;

    # This is EXACTLY the pre-existing on-disk/S3 format: every archive already
    # uploaded was written by this code path.
    my $body = "id,level\n" . ("9,error\n" x 3000);
    my $tar  = Archive::Tar->new();
    $tar->add_data('logs.csv',   $body);
    $tar->add_data('alerts.csv', "x\n");

    my $archive = File::Spec->catfile($dir, 'compat_theirs.tar.gz');
    $tar->write($archive, Archive::Tar::COMPRESS_GZIP());

    my $out = File::Spec->catdir($dir, 'compat_out');
    mkdir $out;
    my $names = extract_tar_gz($archive, $out);

    is_deeply [sort @$names], ['alerts.csv', 'logs.csv'], 'both members extracted';
    is slurp(File::Spec->catfile($out, 'logs.csv')), $body, 'legacy archive extracts byte-identically';
};

# ============================================
# Block-boundary edge cases. ustar pads every member to 512 bytes; get the
# padding wrong by one byte and every LATER member decodes as garbage, which
# is the kind of corruption that only shows up on the archive nobody tested.
# ============================================
subtest 'sizes around the 512-byte block boundary' => sub {
    for my $size (0, 1, 511, 512, 513, 1024) {
        my $src = File::Spec->catdir($dir, "b_$size");
        my $out = File::Spec->catdir($dir, "b_${size}_out");
        mkdir $src; mkdir $out;

        my $body = 'x' x $size;
        write_file(File::Spec->catfile($src, 'a.csv'), $body);
        # A second member proves the padding left the stream aligned.
        write_file(File::Spec->catfile($src, 'b.csv'), 'tail');

        my $archive = File::Spec->catfile($dir, "b_$size.tar.gz");
        write_tar_gz($archive, [
            { name => 'a.csv', path => File::Spec->catfile($src, 'a.csv') },
            { name => 'b.csv', path => File::Spec->catfile($src, 'b.csv') },
        ]);

        extract_tar_gz($archive, $out);
        is slurp(File::Spec->catfile($out, 'a.csv')), $body, "$size-byte member survives";
        is slurp(File::Spec->catfile($out, 'b.csv')), 'tail',
            "the member AFTER a $size-byte one is still aligned";
    }
};

subtest 'permission bits survive the round trip' => sub {
    require Archive::Tar;

    my $src = File::Spec->catdir($dir, 'perm_src');
    mkdir $src;
    my $path = write_file(File::Spec->catfile($src, 'logs.csv'), "secret\n");
    chmod 0640, $path or plan skip_all => 'chmod unsupported here';

    my $archive = File::Spec->catfile($dir, 'perm.tar.gz');
    write_tar_gz($archive, [ { name => 'logs.csv', path => $path } ]);

    my $tar = Archive::Tar->new();
    $tar->read($archive);
    my ($f) = $tar->get_files;
    is sprintf('%04o', $f->mode), '0640', 'mode recorded in the ustar header';
};

subtest 'a name too long for ustar is refused, not silently truncated' => sub {
    my $src = File::Spec->catdir($dir, 'name_src');
    mkdir $src;
    my $path = write_file(File::Spec->catfile($src, 'x.csv'), "1\n");

    my $ok_name = 'n' x 100;
    my $archive = File::Spec->catfile($dir, 'name_ok.tar.gz');
    eval { write_tar_gz($archive, [ { name => $ok_name, path => $path } ]); 1 }
        or diag "100-char name should be accepted: $@";
    ok -s $archive, 'a 100-byte name is accepted';

    my $too_long = 'n' x 101;
    my $bad = File::Spec->catfile($dir, 'name_bad.tar.gz');
    eval { write_tar_gz($bad, [ { name => $too_long, path => $path } ]); 1 };
    like $@, qr/name too long/i, '101 bytes is a hard error';
    ok !-e $bad, 'and no partial archive is left where a caller could pick it up';
};

# ============================================
# Corruption is an error, not a short extraction. A truncated download that
# extracted "successfully" would restore a partial table and report success.
# ============================================
subtest 'truncated and corrupt archives are rejected' => sub {
    my $src = File::Spec->catdir($dir, 'corrupt_src');
    my $out = File::Spec->catdir($dir, 'corrupt_out');
    mkdir $src; mkdir $out;

    # Deliberately not very compressible, so cutting the gzip stream really
    # does cut member bytes rather than just the trailer.
    my $body = join '', map { chr(32 + ($_ * 37 % 90)) } 1 .. 300_000;
    write_file(File::Spec->catfile($src, 'logs.csv'), $body);

    my $archive = File::Spec->catfile($dir, 'corrupt.tar.gz');
    write_tar_gz($archive, [ { name => 'logs.csv', path => File::Spec->catfile($src, 'logs.csv') } ]);

    my $bytes = slurp($archive);
    cmp_ok length($bytes), '>', 1000, 'archive is big enough for a meaningful cut';

    my $cut = File::Spec->catfile($dir, 'corrupt_cut.tar.gz');
    write_file($cut, substr($bytes, 0, int(length($bytes) * 0.6)));

    eval { extract_tar_gz($cut, $out); 1 };
    ok $@, 'a truncated archive dies rather than extracting a partial table';
    like $@, qr/corrupt archive/i, "and says why: $@";
};

subtest 'a header with a bad checksum is rejected' => sub {
    require IO::Compress::Gzip;
    require IO::Uncompress::Gunzip;

    my $src = File::Spec->catdir($dir, 'cks_src');
    my $out = File::Spec->catdir($dir, 'cks_out');
    mkdir $src; mkdir $out;
    write_file(File::Spec->catfile($src, 'logs.csv'), 'z' x 100);

    my $archive = File::Spec->catfile($dir, 'cks.tar.gz');
    write_tar_gz($archive, [ { name => 'logs.csv', path => File::Spec->catfile($src, 'logs.csv') } ]);

    # Rewrite the member name without fixing the checksum.
    my $plain = '';
    IO::Uncompress::Gunzip::gunzip($archive, \$plain) or die 'gunzip failed';
    substr($plain, 0, 8) = 'hacked!!';
    my $tampered = File::Spec->catfile($dir, 'cks_bad.tar.gz');
    IO::Compress::Gzip::gzip(\$plain, $tampered) or die 'gzip failed';

    eval { extract_tar_gz($tampered, $out); 1 };
    like $@, qr/checksum/i, 'tampered header is caught';
};

subtest 'accept() decides what lands on disk' => sub {
    require Archive::Tar;

    # Storage::ClickHouse::Backup passes an accept() that flattens the path and
    # only allows <word>.csv — this is the path-traversal defence for an
    # archive that came back from S3.
    my $tar = Archive::Tar->new();
    $tar->add_data('../../etc/evil.csv', "pwned\n");
    $tar->add_data('nested/logs.csv',    "ok\n");
    $tar->add_data('notes.txt',          "skip\n");

    my $archive = File::Spec->catfile($dir, 'accept.tar.gz');
    $tar->write($archive, Archive::Tar::COMPRESS_GZIP());

    my $out = File::Spec->catdir($dir, 'accept_out');
    mkdir $out;

    my $names = extract_tar_gz($archive, $out, accept => sub {
        my ($name) = @_;
        $name =~ s{^.*/}{};
        return undef unless $name =~ /^[\w\-]+\.csv$/;
        return $name;
    });

    is_deeply [sort @$names], ['evil.csv', 'logs.csv'], 'names flattened, .txt skipped';
    ok -f File::Spec->catfile($out, 'evil.csv'), 'the traversal member landed INSIDE the dest dir';
    ok !-e File::Spec->catfile($dir, '..', 'etc', 'evil.csv'), 'nothing written outside it';
    is slurp(File::Spec->catfile($out, 'logs.csv')), "ok\n", 'skipped members did not desync the stream';
};

# ============================================
# THE memory claim, as a number.
#
# 64 MiB of member data. Both probes count the size of every buffer that
# actually carries member bytes:
#
#   write   — every $gz->print() call from _write_entry
#   extract — every read() the gunzip stream serves
#
# Slurping the file makes the maximum jump from 65_536 to 67_108_864, so the
# assertions below are exactly the mutation detector for "went back to
# add_data / get_content".
# ============================================
my $BIG_MB    = 64;
my $BIG_BYTES = $BIG_MB * 1024 * 1024;
my $CHUNK     = $Purl::Util::TarStream::CHUNK_SIZE;

my $big_src  = File::Spec->catdir($dir, 'big_src');
my $big_out  = File::Spec->catdir($dir, 'big_out');
mkdir $big_src; mkdir $big_out;
my $big_file = File::Spec->catfile($big_src, 'logs.csv');
my $big_arch = File::Spec->catfile($dir, 'big.tar.gz');

# Built a MiB at a time on purpose: assembling 64 MiB in one scalar here would
# pollute the RSS baseline the last subtest measures against.
{
    open my $fh, '>:raw', $big_file or die "Cannot write $big_file: $!";
    for my $i (1 .. $BIG_MB) {
        print {$fh} (chr(65 + ($i % 26)) x (1024 * 1024));
    }
    close $fh;
}
is -s $big_file, $BIG_BYTES, "built a ${BIG_MB} MiB synthetic member";

# Taken HERE, before any archiving, and used by the RSS subtest at the end.
# Measuring it inside that subtest instead would be worthless: Perl never
# returns freed memory to the OS, so a slurp in an EARLIER subtest would
# already have raised the floor and the growth would read as zero.
my $RSS_BASELINE = _rss_kb();

subtest "write never buffers more than $CHUNK bytes of member data" => sub {
    my $max   = 0;
    my $calls = 0;

    my $orig = IO::Compress::Gzip->can('print');
    {
        no warnings 'redefine', 'once';
        no strict 'refs';
        local *IO::Compress::Gzip::print = sub {
            my $len = defined $_[1] ? length $_[1] : 0;
            $max = $len if $len > $max;
            $calls++;
            return $orig->(@_);
        };

        write_tar_gz($big_arch, [ { name => 'logs.csv', path => $big_file } ]);
    }

    ok -s $big_arch, 'archive written';
    cmp_ok $max, '<=', $CHUNK,
        "largest single write of member data was $max bytes (limit $CHUNK)";
    cmp_ok $calls, '>=', $BIG_BYTES / $CHUNK,
        "member was written in $calls calls, i.e. actually chunked";
};

subtest "extract never buffers more than $CHUNK bytes of member data" => sub {
    my $max = 0;

    my $orig = IO::Uncompress::Base->can('READ');
    {
        no warnings 'redefine';
        no strict 'refs';
        local *IO::Uncompress::Base::READ = sub {
            my $n = $orig->(@_);
            $max = $n if defined $n && $n > $max;
            return $n;
        };

        extract_tar_gz($big_arch, $big_out);
    }

    is -s File::Spec->catfile($big_out, 'logs.csv'), $BIG_BYTES,
        'the whole member was extracted';
    cmp_ok $max, '<=', $CHUNK,
        "largest single read of member data was $max bytes (limit $CHUNK)";
};

subtest 'process RSS does not track archive size' => sub {
    plan skip_all => 'ps(1) does not report RSS here' unless defined $RSS_BASELINE;

    my $arch2 = File::Spec->catfile($dir, 'big2.tar.gz');
    my $out2  = File::Spec->catdir($dir, 'big_out2');
    mkdir $out2;

    write_tar_gz($arch2, [ { name => 'logs.csv', path => $big_file } ]);
    extract_tar_gz($arch2, $out2);

    my $growth = _rss_kb() - $RSS_BASELINE;

    # High-water mark since $RSS_BASELINE, which covers every archive written
    # in this file: a single slurped 64 MiB member anywhere above is unmissable.
    my $limit = 16 * 1024;    # KiB
    cmp_ok $growth, '<', $limit,
        "peak RSS grew ${growth} KiB across ${BIG_MB} MiB written+extracted twice (limit ${limit} KiB)";
};

sub _rss_kb {
    my $out = `ps -o rss= -p $$ 2>/dev/null`;
    return undef unless defined $out;
    $out =~ s/\s+//g;
    return $out =~ /^\d+$/ ? $out + 0 : undef;
}

done_testing();

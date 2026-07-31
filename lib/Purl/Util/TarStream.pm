package Purl::Util::TarStream;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use File::Spec;
use IO::Compress::Gzip ();
use IO::Uncompress::Gunzip ();

our @EXPORT_OK = qw(write_tar_gz extract_tar_gz);

# ============================================
# Streaming tar.gz — nothing bigger than one chunk is ever in memory.
# ============================================
#
# Archive::Tar cannot do this. Writing means handing it the FULL contents of
# every member (add_data), and reading means asking a member for its FULL
# contents (get_content). A backup's logs.csv is routinely gigabytes, so both
# directions OOM-killed the worker — the whole point of streaming the ClickHouse
# export to disk was lost again at the tar step.
#
# Shelling out to tar(1) would also fix it, but it puts the archive format at
# the mercy of whatever binary the base image ships (GNU vs busybox differ on
# flags and on what they do with absolute/relative paths), and it means building
# a command line out of filenames. A ~200-line ustar writer/reader has no such
# ambiguity, needs no new CPAN dependency and no binary, and behaves identically
# in the container and on a developer's laptop.
#
# The format written is POSIX ustar, so ordinary tar(1) and Archive::Tar can
# both still read our archives; the reader accepts anything they produce
# (including the pre-existing archives Archive::Tar wrote).
#
# Lives in Util/ rather than inside Storage::ClickHouse::Backup because tar
# framing is its own responsibility, and that role is already near the size
# where it has to be split rather than grown.

# 64 KiB: the per-file working set of both directions, and the only thing that
# scales with anything. Callers override it in tests to make chunking
# observable; there is no reason to tune it in production.
our $CHUNK_SIZE = 65_536;

my $BLOCK = 512;

# Largest size expressible in the 11 octal digits of a ustar size field.
# Above it the GNU base-256 encoding is used — a backup CAN be over 8 GiB, and
# silently truncating the recorded size would produce an archive that extracts
# to garbage.
my $MAX_OCTAL_SIZE = 8_589_934_592;    # 2**33

# ============================================
# Writing
# ============================================

# write_tar_gz($archive_path, \@entries, %opt)
#
#   @entries = ( { name => 'logs.csv', path => '/abs/logs.csv' }, ... )
#
# Writes to a temp file and renames, so a failure part-way through never leaves
# a half-written archive where the "reuse a recent archive" check would find it
# and hand it to a caller as a complete backup.
sub write_tar_gz {
    my ($archive_path, $entries, %opt) = @_;

    my $chunk = $opt{chunk_size} || $CHUNK_SIZE;
    my $tmp   = "$archive_path.tmp.$$";

    my $ok = eval {
        my $gz = IO::Compress::Gzip->new($tmp)
            or die "Cannot create $tmp: $IO::Compress::Gzip::GzipError\n";

        for my $entry (@$entries) {
            _write_entry($gz, $entry, $chunk);
        }

        # End of archive: two zero blocks.
        $gz->print("\0" x ($BLOCK * 2)) or die "Cannot write $tmp: $!\n";
        $gz->close or die "Cannot close $tmp: $!\n";
        1;
    };
    my $err = $@;

    unless ($ok) {
        unlink $tmp;
        die $err || "Failed to write $archive_path\n";
    }

    rename $tmp, $archive_path
        or do { my $e = $!; unlink $tmp; die "Cannot rename $tmp to $archive_path: $e\n" };

    return $archive_path;
}

sub _write_entry {
    my ($gz, $entry, $chunk) = @_;

    my $path = $entry->{path};
    my $name = $entry->{name};

    # Permission bits only — mask off the file-type bits stat() packs into
    # the same field. oct() rather than a leading-zero literal so Perl::Critic
    # does not have to guess whether the zero was a typo.
    my $PERM_MASK = oct('7777');

    my @st = stat $path or die "Cannot stat $path: $!\n";
    my ($mode, $size, $mtime) = ($st[2] & $PERM_MASK, $st[7], $st[9]);

    open my $fh, '<:raw', $path or die "Cannot read $path: $!\n";
    $gz->print(_ustar_header($name, $size, $mtime, $mode))
        or die "Cannot write header for $name: $!\n";

    my $written = 0;
    my $buf     = '';
    while (1) {
        my $n = read $fh, $buf, $chunk;
        die "Read failed on $path: $!\n" unless defined $n;
        last unless $n;

        # A member longer than its header claims desynchronises every later
        # member. Stop rather than emit an archive that extracts to garbage.
        die "$path grew while being archived\n" if $written + $n > $size;

        $gz->print($buf) or die "Cannot write body for $name: $!\n";
        $written += $n;
    }
    close $fh;

    die "$path shrank while being archived\n" if $written != $size;

    my $pad = ($BLOCK - ($size % $BLOCK)) % $BLOCK;
    if ($pad) {
        $gz->print("\0" x $pad) or die "Cannot write padding for $name: $!\n";
    }

    return 1;
}

sub _ustar_header {
    my ($name, $size, $mtime, $mode) = @_;

    die "Archive entry name too long (max 100 bytes): $name\n"
        if length($name) > 100;

    # 'A8' for the checksum field pads with SPACES, which is exactly what the
    # checksum must be computed over.
    my $header = pack(
        'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
        $name,
        sprintf('%07o', $mode) . "\0",
        sprintf('%07o', 0) . "\0",
        sprintf('%07o', 0) . "\0",
        _encode_size($size),
        sprintf('%011o', $mtime) . "\0",
        '',            # checksum, filled in below
        '0',           # typeflag: regular file
        '',            # linkname
        'ustar', '00',
        'root', 'root',
        sprintf('%07o', 0) . "\0",
        sprintf('%07o', 0) . "\0",
        '',            # prefix
    );

    my $sum = 0;
    $sum += $_ for unpack 'C*', $header;
    substr($header, 148, 8) = sprintf('%06o', $sum) . "\0 ";

    return $header;
}

sub _encode_size {
    my ($size) = @_;
    return sprintf('%011o', $size) . "\0" if $size < $MAX_OCTAL_SIZE;

    # GNU base-256: high bit set on the first byte, value big-endian in the
    # rest. 12 bytes = 1 marker + 3 zero + 64 bits of magnitude.
    return "\x80" . ("\0" x 3) . pack('N2', $size >> 32, $size & 0xFFFFFFFF);
}

# ============================================
# Reading
# ============================================

# extract_tar_gz($archive_path, $dest_dir, %opt) -> \@extracted_names
#
#   accept => sub { my ($name) = @_; ... }
#       Maps an archive member name to the basename to write under $dest_dir,
#       or undef to skip the member entirely. This is the ONLY place the caller
#       gets to decide what lands on disk, so path-traversal defence belongs in
#       it — see the caller in Storage::ClickHouse::Backup.
sub extract_tar_gz {
    my ($archive_path, $dest_dir, %opt) = @_;

    my $chunk  = $opt{chunk_size} || $CHUNK_SIZE;
    my $accept = $opt{accept} || sub { return $_[0] };

    my $z = IO::Uncompress::Gunzip->new($archive_path)
        or die "Cannot read $archive_path: $IO::Uncompress::Gunzip::GunzipError\n";

    my @extracted;
    my $saw_end = 0;
    while (1) {
        my $header = _read_exactly($z, $BLOCK);
        last unless defined $header;
        if ($header !~ /[^\0]/) {          # end-of-archive marker
            $saw_end = 1;
            last;
        }

        _verify_checksum($header);

        my $name     = unpack 'Z100', $header;
        my $size     = _decode_size(substr($header, 124, 12));
        my $typeflag = substr($header, 156, 1);
        my $pad      = ($BLOCK - ($size % $BLOCK)) % $BLOCK;

        my $is_file = ($typeflag eq '0' || $typeflag eq "\0") ? 1 : 0;
        my $out_name = $is_file ? $accept->($name) : undef;

        if (defined $out_name && length $out_name) {
            my $out = File::Spec->catfile($dest_dir, $out_name);
            open my $fh, '>:raw', $out or die "Cannot write $out: $!\n";
            _copy_stream($z, $fh, $size, $chunk);
            close $fh or die "Cannot close $out: $!\n";
            push @extracted, $out_name;
        }
        else {
            _copy_stream($z, undef, $size, $chunk);
        }

        _copy_stream($z, undef, $pad, $chunk) if $pad;
    }

    $z->close;

    # A stream that simply RAN OUT is not a finished archive. Without this a
    # half-downloaded backup extracts whatever members happened to arrive and
    # reports success, and the restore that follows silently loses the rest of
    # the table. Every writer — ours and Archive::Tar's — emits the two zero
    # blocks, so their absence means truncation.
    die "Corrupt archive: no end-of-archive marker (truncated download?)\n"
        unless $saw_end;

    return \@extracted;
}

sub _verify_checksum {
    my ($header) = @_;

    # Leading spaces first: some writers right-align the field, and trimming at
    # the first non-octal byte before stripping them would leave nothing.
    my $stored = substr($header, 148, 8);
    $stored =~ s/\A\s+//;
    $stored =~ s/[^0-7].*\z//s;
    die "Corrupt archive: unreadable header checksum\n" unless length $stored;

    my $blanked = $header;
    substr($blanked, 148, 8) = ' ' x 8;
    my $sum = 0;
    $sum += $_ for unpack 'C*', $blanked;

    die "Corrupt archive: header checksum mismatch\n" if $sum != _oct($stored);
    return 1;
}

# oct() is not usable here: it warns "Octal number > 037777777777 non-portable"
# for anything above 2**32. The value it returns is correct on a 64-bit perl,
# but this module exists FOR members that large — so every multi-gigabyte
# restore sprayed that line into the worker log while decoding a size it had
# got right. $digits is already trimmed to octal digits by both callers, so
# folding them by hand is exact and silent.
sub _oct {
    my ($digits) = @_;

    my $value = 0;
    $value = $value * 8 + ($_ - ord('0')) for unpack 'C*', $digits;
    return $value;
}

sub _decode_size {
    my ($field) = @_;

    return _decode_base256($field) if ord(substr($field, 0, 1)) & 0x80;

    $field =~ s/\A\s+//;
    $field =~ s/[^0-7].*\z//s;
    return length($field) ? _oct($field) : 0;
}

sub _decode_base256 {
    my ($field) = @_;
    my $value = 0;
    $value = $value * 256 + $_ for unpack 'C*', substr($field, 1);
    return $value;
}

# Read exactly $want bytes. undef means "the stream ended cleanly here"; a
# partial read means the archive is truncated, which is an error — silently
# treating it as end-of-archive is how a half-downloaded backup restores as a
# successful, incomplete restore.
sub _read_exactly {
    my ($z, $want) = @_;

    my $data = '';
    my $buf  = '';
    while (length($data) < $want) {
        my $n = read $z, $buf, $want - length($data);
        die "Corrupt archive: read failed: $!\n" unless defined $n;
        last unless $n;
        $data .= $buf;
    }

    return undef unless length $data;
    die "Corrupt archive: truncated header\n" if length($data) < $want;
    return $data;
}

# Move exactly $bytes from the archive stream to $out (or discard when $out is
# undef), $chunk bytes at a time. This is the reason extraction is not
# RAM-bound.
sub _copy_stream {
    my ($z, $out, $bytes, $chunk) = @_;

    my $left = $bytes;
    my $buf  = '';
    while ($left > 0) {
        my $want = $left < $chunk ? $left : $chunk;
        my $n = read $z, $buf, $want;
        die "Corrupt archive: read failed: $!\n" unless defined $n;
        die "Corrupt archive: truncated member data\n" unless $n;
        if ($out) {
            print {$out} $buf or die "Cannot write extracted data: $!\n";
        }
        $left -= $n;
    }

    return 1;
}

1;

__END__

=head1 NAME

Purl::Util::TarStream - streaming tar.gz writer and extractor

=head1 SYNOPSIS

    use Purl::Util::TarStream qw(write_tar_gz extract_tar_gz);

    write_tar_gz('/backups/b1.tar.gz', [
        { name => 'logs.csv', path => '/backups/b1/logs.csv' },
    ]);

    my $names = extract_tar_gz('/tmp/b1.tar.gz', '/tmp/out', accept => sub {
        my ($name) = @_;
        $name =~ s{\A.*/}{};
        return $name =~ /\A[\w\-]+\.csv\z/ ? $name : undef;
    });

=head1 MEMORY

Both directions hold at most C<$CHUNK_SIZE> (64 KiB) of member data at a time,
plus gzip's own fixed window. Archive size does not affect memory use. This is
the only reason this module exists: L<Archive::Tar> requires the whole of each
member in a scalar, in both directions.

=head1 FORMAT

POSIX ustar. Member names are limited to 100 bytes (the C<prefix> field is
written empty and ignored on read; every caller here uses flat basenames).
Sizes of 8 GiB and over use the GNU base-256 encoding, which is also accepted
on read.

Header checksums are verified on read; a mismatch or a truncated stream is a
fatal error rather than a silently short extraction.

=cut

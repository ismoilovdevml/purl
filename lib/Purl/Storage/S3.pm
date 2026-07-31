package Purl::Storage::S3;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use Digest::SHA qw(sha256_hex hmac_sha256 hmac_sha256_hex);
use POSIX qw(strftime);
use URI::Escape qw(uri_escape);

has 'bucket'     => (is => 'ro', required => 1);
has 'region'     => (is => 'ro', default => sub { 'us-east-1' });
has 'access_key' => (is => 'ro', required => 1);
has 'secret_key' => (is => 'ro', required => 1);
has 'prefix'     => (is => 'ro', default => sub { 'purl-backups/' });
has 'endpoint'   => (is => 'ro', default => sub { '' });

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { HTTP::Tiny->new(timeout => 300) },
);

# Bytes per read when streaming a body to/from disk. Backups are routinely
# larger than RAM, so nothing here may slurp a whole object.
my $CHUNK_SIZE = 1024 * 256;

sub _s3_host {
    my ($self) = @_;
    if ($self->endpoint && $self->endpoint ne '') {
        my $ep = $self->endpoint;
        $ep =~ s{/$}{};
        return $ep;
    }
    return "https://${\$self->bucket}.s3.${\$self->region}.amazonaws.com";
}

sub _host_header {
    my ($self) = @_;
    my $h = $self->_s3_host;
    $h =~ s{^https?://}{};
    $h =~ s{/.*$}{};
    return $h;
}

# Percent-encode a path so each '/' stays a separator but every other
# reserved character in the key is escaped — S3 keys may legally contain
# spaces, '+', '#' and friends, and an unescaped one both breaks the request
# and invalidates the signature (the canonical request must use the SAME
# encoding as the URI).
sub _encode_key_path {
    my ($self, $key) = @_;
    return '/' . join('/', map { uri_escape($_, q{^A-Za-z0-9\-._~}) } split m{/}, $key, -1);
}

# Canonical query string: sorted by key, both key and value percent-encoded.
sub _canonical_query {
    my ($self, $query) = @_;
    return '' unless $query && %$query;
    return join('&',
        map { uri_escape($_, q{^A-Za-z0-9\-._~}) . '=' . uri_escape($query->{$_}, q{^A-Za-z0-9\-._~}) }
        sort keys %$query);
}

sub _sign_v4 {
    my ($self, %params) = @_;

    my $method       = $params{method};
    my $path         = $params{path};
    my $headers      = $params{headers};
    my $query_string = $params{query_string} // '';
    # Callers that stream a body pass the digest directly instead of the bytes.
    my $payload_hash = $params{payload_hash} // sha256_hex($params{payload} // '');

    my $date_stamp = strftime('%Y%m%d', gmtime());
    my $amz_date   = strftime('%Y%m%dT%H%M%SZ', gmtime());

    $headers->{'x-amz-date'}           = $amz_date;
    $headers->{'x-amz-content-sha256'} = $payload_hash;

    # Canonical request
    my @signed_header_names = sort keys %$headers;
    my $signed_headers = join(';', map { lc($_) } @signed_header_names);
    my $canonical_headers = join('', map { lc($_) . ':' . $headers->{$_} . "\n" } @signed_header_names);

    my $canonical_request = join("\n",
        $method,
        $path,
        $query_string,
        $canonical_headers,
        $signed_headers,
        $payload_hash,
    );

    # String to sign
    my $scope = "${date_stamp}/${\$self->region}/s3/aws4_request";
    my $string_to_sign = join("\n",
        'AWS4-HMAC-SHA256',
        $amz_date,
        $scope,
        sha256_hex($canonical_request),
    );

    # Signing key
    my $k_date    = hmac_sha256($date_stamp,    'AWS4' . $self->secret_key);
    my $k_region  = hmac_sha256($self->region,   $k_date);
    my $k_service = hmac_sha256('s3',            $k_region);
    my $k_signing = hmac_sha256('aws4_request',  $k_service);

    my $signature = hmac_sha256_hex($string_to_sign, $k_signing);

    $headers->{'Authorization'} = "AWS4-HMAC-SHA256 "
        . "Credential=${\$self->access_key}/$scope, "
        . "SignedHeaders=$signed_headers, "
        . "Signature=$signature";

    return $headers;
}

# One signed request. Every verb goes through here so signing can never drift
# between operations (the whole reason download/list/delete were missing for so
# long was that each one looked like "another 40 lines of signing code").
sub _request {
    my ($self, %params) = @_;

    my $method  = $params{method};
    my $path    = $params{path};                 # already '/'-prefixed, raw (unencoded)
    my $query   = $params{query} // {};
    my %headers = %{ $params{headers} // {} };

    $headers{'Host'} = $self->_host_header;

    my $encoded_path  = $self->_encode_key_path($path =~ s{^/}{}r);
    my $query_string  = $self->_canonical_query($query);

    $self->_sign_v4(
        method       => $method,
        path         => $encoded_path,
        query_string => $query_string,
        headers      => \%headers,
        payload      => $params{payload},
        payload_hash => $params{payload_hash},
    );

    my $url = $self->_s3_host . $encoded_path;
    $url .= '?' . $query_string if $query_string ne '';

    my %options = (headers => \%headers);
    $options{content}       = $params{payload}       if defined $params{payload};
    $options{content}       = $params{content_cb}    if $params{content_cb};
    $options{data_callback} = $params{data_callback} if $params{data_callback};

    return $self->_http->request($method, $url, \%options);
}

sub _full_key {
    my ($self, $s3_key) = @_;
    return $self->prefix . $s3_key;
}

# Streaming SHA-256 of a file — never loads the file into memory.
sub _file_sha256 {
    my ($self, $file_path) = @_;
    my $sha = Digest::SHA->new(256);
    $sha->addfile($file_path);
    return $sha->hexdigest;
}

# ============================================
# Object operations
# ============================================

sub upload_file {
    my ($self, %params) = @_;

    my $file_path = $params{file_path} or die "file_path required";
    my $s3_key    = $params{s3_key}    or die "s3_key required";

    die "File not found: $file_path" unless -f $file_path;

    my $size = -s $file_path;
    my $full_key = $self->_full_key($s3_key);

    # Two passes over the file (hash, then send) instead of one slurp: SigV4
    # needs the payload digest up front, and a backup archive does not fit in
    # RAM. Content-Length is set explicitly so HTTP::Tiny sends a plain body
    # rather than switching to chunked encoding, which S3 rejects without
    # aws-chunked signing.
    my $payload_hash = $self->_file_sha256($file_path);

    open my $fh, '<:raw', $file_path or die "Cannot read $file_path: $!";
    my $content_cb = sub {
        my $buffer = '';
        my $read = read $fh, $buffer, $CHUNK_SIZE;
        return defined $read && $read > 0 ? $buffer : '';
    };

    my $response = $self->_request(
        method  => 'PUT',
        path    => "/$full_key",
        headers => {
            'Content-Type'   => 'application/gzip',
            'Content-Length' => $size,
        },
        payload_hash => $payload_hash,
        content_cb   => $content_cb,
    );
    close $fh;

    unless ($response->{success}) {
        die "S3 upload failed: $response->{status} - $response->{content}";
    }

    return "s3://${\$self->bucket}/$full_key";
}

# Download an object straight to disk. Returns the destination path.
sub download_file {
    my ($self, %params) = @_;

    my $s3_key   = $params{s3_key}    or die "s3_key required";
    my $dest     = $params{dest_path} or die "dest_path required";
    my $full_key = $self->_full_key($s3_key);

    open my $fh, '>:raw', $dest or die "Cannot write $dest: $!";

    my $response = eval {
        $self->_request(
            method        => 'GET',
            path          => "/$full_key",
            data_callback => sub { print {$fh} $_[0] },
        );
    };
    my $err = $@;
    close $fh;

    if ($err) {
        unlink $dest;
        die $err;
    }

    unless ($response->{success}) {
        unlink $dest;
        die "S3 download failed: $response->{status} - $response->{content}";
    }

    return $dest;
}

# List object keys under a prefix. Returns an arrayref of keys RELATIVE to
# $self->prefix, so callers speak the same key space as upload/download.
sub list_objects {
    my ($self, %params) = @_;

    my $sub_prefix = $self->prefix . ($params{prefix} // '');
    my @keys;
    my $token;

    # S3 caps a page at 1000 keys; follow the continuation token so a large
    # bucket is not silently truncated to its first page.
    for (1 .. 1000) {
        my %query = ('list-type' => 2, 'prefix' => $sub_prefix);
        $query{'continuation-token'} = $token if defined $token;

        my $response = $self->_request(
            method => 'GET',
            path   => '/',
            query  => \%query,
        );

        unless ($response->{success}) {
            die "S3 list failed: $response->{status} - $response->{content}";
        }

        my $body = $response->{content} // '';
        while ($body =~ m{<Key>(.*?)</Key>}gs) {
            my $key = _xml_unescape($1);
            $key =~ s/^\Q@{[$self->prefix]}\E//;
            push @keys, $key;
        }

        last unless $body =~ m{<IsTruncated>\s*true\s*</IsTruncated>}i;
        ($token) = $body =~ m{<NextContinuationToken>(.*?)</NextContinuationToken>}s;
        last unless defined $token && length $token;
        $token = _xml_unescape($token);
    }

    return \@keys;
}

sub delete_object {
    my ($self, %params) = @_;

    my $s3_key = $params{s3_key} or die "s3_key required";
    my $full_key = $self->_full_key($s3_key);

    my $response = $self->_request(
        method => 'DELETE',
        path   => "/$full_key",
    );

    # S3 DELETE is idempotent: a missing key answers 204, not 404. Anything
    # else is a real failure and must not be swallowed — a silent failure here
    # is how buckets grow forever.
    unless ($response->{success} || ($response->{status} // 0) == 404) {
        die "S3 delete failed: $response->{status} - $response->{content}";
    }

    return 1;
}

sub _xml_unescape {
    my ($text) = @_;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#39;/'/g;
    $text =~ s/&amp;/&/g;
    return $text;
}

# ============================================
# s3:// URI helpers
# ============================================

# Parse "s3://bucket/prefix/id.tar.gz" -> { bucket, key }. Returns undef for
# anything that is not an s3 URI, so callers can use it as the "is this
# remote?" test as well.
sub parse_uri {
    my ($class_or_self, $uri) = @_;
    return undef unless defined $uri && $uri =~ m{^s3://([^/]+)/(.+)$};
    return { bucket => $1, key => $2 };
}

# Resolve the backup S3 configuration from ENV, falling back to persisted
# settings. Lives here rather than being re-typed in Server.pm and
# Controller::Backup (it was, three times, with drifting defaults) so every
# S3 operation — upload, restore, delete, retention cleanup — resolves the
# same bucket with the same credentials.
sub config_from {
    my ($class, %args) = @_;
    my $settings = $args{settings};

    my $stored = sub {
        my ($key) = @_;
        return undef unless $settings;
        return $settings->get('backup', $key);
    };

    return {
        enabled    => $ENV{PURL_BACKUP_S3_ENABLED}  // $stored->('s3_enabled')     // 0,
        bucket     => $ENV{PURL_BACKUP_S3_BUCKET}   // $stored->('s3_bucket')      // '',
        region     => $ENV{PURL_BACKUP_S3_REGION}   // $stored->('s3_region')      // 'us-east-1',
        prefix     => $ENV{PURL_BACKUP_S3_PREFIX}   // $stored->('s3_prefix')      // 'purl-backups/',
        access_key => $ENV{AWS_ACCESS_KEY_ID}       // $stored->('s3_access_key')  // '',
        secret_key => $ENV{AWS_SECRET_ACCESS_KEY}   // $stored->('s3_secret_key')  // '',
        endpoint   => $ENV{PURL_BACKUP_S3_ENDPOINT} // $stored->('s3_endpoint')    // '',
    };
}

# True when the config carries everything an S3 call needs.
sub config_is_usable {
    my ($class, $config) = @_;
    return 0 unless $config;
    return ($config->{bucket} && $config->{access_key} && $config->{secret_key}) ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::Storage::S3 - Minimal S3 client for backup archives

=head1 DESCRIPTION

GetObject / PutObject / ListObjectsV2 / DeleteObject over HTTP::Tiny with
inline AWS Signature V4. Works against standard S3 and S3-compatible
endpoints (MinIO, Ceph, R2, ...). No AWS SDK dependency.

Uploads and downloads stream through a fixed-size buffer, so object size is
bounded by disk, not RAM.

=head1 METHODS

=over 4

=item upload_file(file_path => $path, s3_key => $key)

Streams the file to S3. Returns the C<s3://bucket/key> URI.

=item download_file(s3_key => $key, dest_path => $path)

Streams the object to disk. Returns the destination path. Removes a partial
file if the transfer fails.

=item list_objects(prefix => $sub_prefix)

Returns an arrayref of keys relative to the configured prefix, following
continuation tokens.

=item delete_object(s3_key => $key)

Deletes the object. Succeeds when the key is already gone.

=item parse_uri($uri)

Class or instance method. Splits C<s3://bucket/key> into a hashref, or
returns undef when C<$uri> is not an S3 URI.

=back

=cut

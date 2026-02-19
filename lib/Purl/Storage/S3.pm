package Purl::Storage::S3;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use HTTP::Tiny;
use Digest::SHA qw(sha256_hex hmac_sha256 hmac_sha256_hex);
use POSIX qw(strftime);
use URI::Escape qw(uri_escape_utf8);
use MIME::Base64 ();

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

sub _s3_host {
    my ($self) = @_;
    if ($self->endpoint && $self->endpoint ne '') {
        my $ep = $self->endpoint;
        $ep =~ s{/$}{};
        return $ep;
    }
    return "https://${\$self->bucket}.s3.${\$self->region}.amazonaws.com";
}

sub _sign_v4 {
    my ($self, %params) = @_;

    my $method  = $params{method};
    my $path    = $params{path};
    my $headers = $params{headers};
    my $payload = $params{payload} // '';

    my $now = gmtime();
    my $date_stamp = strftime('%Y%m%d', gmtime());
    my $amz_date   = strftime('%Y%m%dT%H%M%SZ', gmtime());

    $headers->{'x-amz-date'}           = $amz_date;
    $headers->{'x-amz-content-sha256'} = sha256_hex($payload);

    # Canonical request
    my @signed_header_names = sort keys %$headers;
    my $signed_headers = join(';', map { lc($_) } @signed_header_names);
    my $canonical_headers = join('', map { lc($_) . ':' . $headers->{$_} . "\n" } @signed_header_names);

    my $canonical_request = join("\n",
        $method,
        $path,
        '',  # query string (empty for PUT)
        $canonical_headers,
        $signed_headers,
        sha256_hex($payload),
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

sub upload_file {
    my ($self, %params) = @_;

    my $file_path = $params{file_path} or die "file_path required";
    my $s3_key    = $params{s3_key}    or die "s3_key required";

    die "File not found: $file_path" unless -f $file_path;

    open my $fh, '<:raw', $file_path or die "Cannot read $file_path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;

    my $full_key = $self->prefix . $s3_key;
    my $url_path = '/' . $full_key;
    my $url = $self->_s3_host . $url_path;

    my %headers = (
        'Content-Type' => 'application/gzip',
        'Host'         => do {
            my $h = $self->_s3_host;
            $h =~ s{^https?://}{};
            $h =~ s{/.*$}{};
            $h;
        },
    );

    $self->_sign_v4(
        method  => 'PUT',
        path    => $url_path,
        headers => \%headers,
        payload => $content,
    );

    my $response = $self->_http->put($url, {
        content => $content,
        headers => \%headers,
    });

    unless ($response->{success}) {
        die "S3 upload failed: $response->{status} - $response->{content}";
    }

    return "s3://${\$self->bucket}/$full_key";
}

1;

__END__

=head1 NAME

Purl::Storage::S3 - S3 object upload for backup archives

=head1 DESCRIPTION

Lightweight S3 PutObject implementation using HTTP::Tiny and AWS Signature V4.
Supports standard S3 and S3-compatible endpoints (MinIO, etc.).

No external AWS dependencies required — signing is implemented inline.

=cut

#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# Purl::Storage::S3 — the half of the client that did not exist.
#
# Before this, S3.pm had only upload_file. Everything downstream assumed a
# backup could be fetched back, listed or deleted; none of those operations
# were implemented, so every backup pushed to S3 was write-only.
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);
use File::Spec;

use Purl::Storage::S3;

# --- Fake HTTP transport ----------------------------------------------------
{
    package FakeHTTP;
    sub new {
        my ($class, %args) = @_;
        return bless { calls => [], responses => $args{responses} // [], body => $args{body} }, $class;
    }
    sub request {
        my ($self, $method, $url, $options) = @_;
        push @{ $self->{calls} }, { method => $method, url => $url, options => $options };

        # Drain a streamed request body so upload tests can assert on it.
        if (ref $options->{content} eq 'CODE') {
            my $sent = '';
            while (1) {
                my $chunk = $options->{content}->();
                last unless defined $chunk && length $chunk;
                $sent .= $chunk;
            }
            $self->{calls}[-1]{sent} = $sent;
        }
        elsif (defined $options->{content}) {
            $self->{calls}[-1]{sent} = $options->{content};
        }

        my $response = shift @{ $self->{responses} }
            // { success => 1, status => 200, content => '', headers => {} };

        if ($options->{data_callback} && $response->{success}) {
            $options->{data_callback}->($_) for @{ $response->{chunks} // [] };
        }
        return $response;
    }
    sub calls { $_[0]->{calls} }
}

sub _s3 {
    my (%args) = @_;
    return Purl::Storage::S3->new(
        bucket     => 'my-bucket',
        region     => 'eu-central-1',
        access_key => 'AKIAEXAMPLE',
        secret_key => 'secret',
        prefix     => 'purl-backups/',
        %args,
    );
}

# ---------------------------------------------------------------------------
# URI parsing
# ---------------------------------------------------------------------------
subtest 'parse_uri splits an s3:// URI' => sub {
    my $parsed = Purl::Storage::S3->parse_uri('s3://my-bucket/purl-backups/backup_1.tar.gz');
    is $parsed->{bucket}, 'my-bucket', 'bucket extracted';
    is $parsed->{key}, 'purl-backups/backup_1.tar.gz', 'key extracted';
};

subtest 'parse_uri rejects non-S3 values' => sub {
    # Parenthesised calls throughout: `is Class->method(...)` parses as an
    # indirect method call on Test::More's `is`.
    is(Purl::Storage::S3->parse_uri('/app/backups/backup_1'), undef, 'local path is not an S3 URI');
    is(Purl::Storage::S3->parse_uri(''), undef, 'empty string');
    is(Purl::Storage::S3->parse_uri(undef), undef, 'undef');
    is(Purl::Storage::S3->parse_uri('s3://bucket-only'), undef, 'bucket with no key');
};

# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------
subtest 'download_file streams the object to disk' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $dest = File::Spec->catfile($dir, 'out.tar.gz');

    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 200, content => '', headers => {},
          chunks => ['chunk-one', 'chunk-two'] },
    ]);
    my $s3 = _s3(_http => $http);

    my $result = $s3->download_file(s3_key => 'backup_1.tar.gz', dest_path => $dest);
    is $result, $dest, 'returns the destination path';

    open my $fh, '<:raw', $dest or die $!;
    local $/;
    is scalar <$fh>, 'chunk-onechunk-two', 'all chunks written in order';
    close $fh;

    my $call = $http->calls->[0];
    is $call->{method}, 'GET', 'issues a GET';
    like $call->{url}, qr{/purl-backups/backup_1\.tar\.gz$}, 'prefix applied to the key';
    like $call->{options}{headers}{'Authorization'}, qr/^AWS4-HMAC-SHA256 /, 'request is signed';
};

subtest 'download_file removes the partial file on failure' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $dest = File::Spec->catfile($dir, 'out.tar.gz');

    my $http = FakeHTTP->new(responses => [
        { success => 0, status => 404, content => 'NoSuchKey', headers => {} },
    ]);
    my $s3 = _s3(_http => $http);

    my $ok = eval { $s3->download_file(s3_key => 'missing.tar.gz', dest_path => $dest); 1 };
    ok !$ok, 'dies on a failed download';
    like $@, qr/S3 download failed: 404/, 'error carries the status';
    ok !-e $dest, 'no truncated file left behind to be mistaken for a backup';
};

# ---------------------------------------------------------------------------
# List
# ---------------------------------------------------------------------------
subtest 'list_objects returns keys relative to the prefix' => sub {
    my $xml = <<'XML';
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult>
  <IsTruncated>false</IsTruncated>
  <Contents><Key>purl-backups/backup_1.tar.gz</Key></Contents>
  <Contents><Key>purl-backups/backup_2.tar.gz</Key></Contents>
</ListBucketResult>
XML
    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 200, content => $xml, headers => {} },
    ]);
    my $s3 = _s3(_http => $http);

    is_deeply $s3->list_objects, ['backup_1.tar.gz', 'backup_2.tar.gz'],
        'prefix stripped from every key';
    like $http->calls->[0]{url}, qr/list-type=2/, 'uses ListObjectsV2';
};

subtest 'list_objects follows the continuation token' => sub {
    my $page1 = '<ListBucketResult><Contents><Key>purl-backups/a.tar.gz</Key></Contents>'
              . '<IsTruncated>true</IsTruncated>'
              . '<NextContinuationToken>tok&amp;1</NextContinuationToken></ListBucketResult>';
    my $page2 = '<ListBucketResult><Contents><Key>purl-backups/b.tar.gz</Key></Contents>'
              . '<IsTruncated>false</IsTruncated></ListBucketResult>';

    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 200, content => $page1, headers => {} },
        { success => 1, status => 200, content => $page2, headers => {} },
    ]);
    my $s3 = _s3(_http => $http);

    is_deeply $s3->list_objects, ['a.tar.gz', 'b.tar.gz'], 'both pages collected';
    is scalar @{ $http->calls }, 2, 'made two requests';
    like $http->calls->[1]{url}, qr/continuation-token=tok%261/,
        'token is percent-encoded in the follow-up request';
};

subtest 'list_objects dies on an error response' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 0, status => 403, content => 'AccessDenied', headers => {} },
    ]);
    my $ok = eval { _s3(_http => $http)->list_objects; 1 };
    ok !$ok, 'does not silently return an empty list on AccessDenied';
    like $@, qr/S3 list failed: 403/, 'error carries the status';
};

# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------
subtest 'delete_object issues a signed DELETE' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 204, content => '', headers => {} },
    ]);
    my $s3 = _s3(_http => $http);

    ok $s3->delete_object(s3_key => 'backup_1.tar.gz'), 'returns true';
    is $http->calls->[0]{method}, 'DELETE', 'issues a DELETE';
    like $http->calls->[0]{url}, qr{/purl-backups/backup_1\.tar\.gz$}, 'correct key';
};

subtest 'delete_object is idempotent for a missing key' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 0, status => 404, content => 'NoSuchKey', headers => {} },
    ]);
    ok _s3(_http => $http)->delete_object(s3_key => 'gone.tar.gz'),
        '404 is success — the object is already absent';
};

subtest 'delete_object propagates a real failure' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 0, status => 403, content => 'AccessDenied', headers => {} },
    ]);
    my $ok = eval { _s3(_http => $http)->delete_object(s3_key => 'x.tar.gz'); 1 };
    ok !$ok, 'AccessDenied is not swallowed';
    like $@, qr/S3 delete failed: 403/, 'error carries the status';
};

# ---------------------------------------------------------------------------
# Upload (streaming)
# ---------------------------------------------------------------------------
subtest 'upload_file streams the file with a Content-Length' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'archive.tar.gz');
    open my $fh, '>:raw', $file or die $!;
    print {$fh} 'x' x 5000;
    close $fh;

    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 200, content => '', headers => {} },
    ]);
    my $s3 = _s3(_http => $http);

    my $uri = $s3->upload_file(file_path => $file, s3_key => 'backup_1.tar.gz');
    is $uri, 's3://my-bucket/purl-backups/backup_1.tar.gz', 'returns the s3:// URI';

    my $call = $http->calls->[0];
    is $call->{method}, 'PUT', 'issues a PUT';
    is $call->{options}{headers}{'Content-Length'}, 5000, 'declares the length (no chunked encoding)';
    is length($call->{sent}), 5000, 'entire file streamed';
    like $call->{options}{headers}{'x-amz-content-sha256'}, qr/^[0-9a-f]{64}$/,
        'payload digest computed without slurping';
};

subtest 'upload_file refuses a missing file' => sub {
    my $ok = eval { _s3(_http => FakeHTTP->new)->upload_file(file_path => '/nope', s3_key => 'k'); 1 };
    ok !$ok, 'dies when the file does not exist';
};

# ---------------------------------------------------------------------------
# Key encoding — a key with reserved characters must not break the signature
# ---------------------------------------------------------------------------
subtest 'keys with reserved characters are percent-encoded' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 204, content => '', headers => {} },
    ]);
    my $s3 = _s3(_http => $http);
    $s3->delete_object(s3_key => 'my backup+2024.tar.gz');

    my $url = $http->calls->[0]{url};
    like $url, qr/my%20backup%2B2024\.tar\.gz/, 'space and plus escaped';
    unlike $url, qr/ /, 'no raw space in the URL';
};

subtest 'path separators survive encoding' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 204, content => '', headers => {} },
    ]);
    my $s3 = _s3(_http => $http, prefix => 'nested/dir/');
    $s3->delete_object(s3_key => 'sub/backup.tar.gz');
    like $http->calls->[0]{url}, qr{/nested/dir/sub/backup\.tar\.gz$},
        'slashes stay slashes';
};

# ---------------------------------------------------------------------------
# Endpoint override (MinIO and friends)
# ---------------------------------------------------------------------------
subtest 'custom endpoint is honoured' => sub {
    my $http = FakeHTTP->new(responses => [
        { success => 1, status => 204, content => '', headers => {} },
    ]);
    my $s3 = _s3(_http => $http, endpoint => 'http://minio.local:9000/');
    $s3->delete_object(s3_key => 'k.tar.gz');
    like $http->calls->[0]{url}, qr{^http://minio\.local:9000/purl-backups/k\.tar\.gz$},
        'endpoint replaces the AWS host and the trailing slash is trimmed';
    is $http->calls->[0]{options}{headers}{Host}, 'minio.local:9000', 'Host header matches';
};

# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------
{
    package FakeSettings;
    sub new { bless { values => $_[1] // {} }, $_[0] }
    sub get { my ($self, $section, $key) = @_; return $self->{values}{"$section.$key"} }
}

subtest 'config_from prefers ENV over stored settings' => sub {
    local $ENV{PURL_BACKUP_S3_BUCKET} = 'env-bucket';
    delete $ENV{PURL_BACKUP_S3_REGION};
    delete $ENV{AWS_ACCESS_KEY_ID};
    delete $ENV{AWS_SECRET_ACCESS_KEY};
    delete $ENV{PURL_BACKUP_S3_PREFIX};
    delete $ENV{PURL_BACKUP_S3_ENDPOINT};
    delete $ENV{PURL_BACKUP_S3_ENABLED};

    my $settings = FakeSettings->new({
        'backup.s3_bucket'     => 'stored-bucket',
        'backup.s3_region'     => 'ap-south-1',
        'backup.s3_access_key' => 'stored-key',
        'backup.s3_secret_key' => 'stored-secret',
    });

    my $config = Purl::Storage::S3->config_from(settings => $settings);
    is $config->{bucket}, 'env-bucket', 'ENV wins';
    is $config->{region}, 'ap-south-1', 'stored value used when ENV is absent';
    is $config->{access_key}, 'stored-key', 'credentials from settings';
    is $config->{prefix}, 'purl-backups/', 'default prefix';
};

subtest 'config_from works with no settings object' => sub {
    delete $ENV{PURL_BACKUP_S3_BUCKET};
    delete $ENV{AWS_ACCESS_KEY_ID};
    delete $ENV{AWS_SECRET_ACCESS_KEY};
    my $config = Purl::Storage::S3->config_from();
    is $config->{bucket}, '', 'empty bucket, not undef';
    is $config->{region}, 'us-east-1', 'default region';
    ok !Purl::Storage::S3->config_is_usable($config), 'incomplete config is not usable';
};

subtest 'config_is_usable requires bucket and both credentials' => sub {
    ok(Purl::Storage::S3->config_is_usable(
        { bucket => 'b', access_key => 'k', secret_key => 's' }), 'complete config');
    ok(!Purl::Storage::S3->config_is_usable(
        { bucket => 'b', access_key => 'k' }), 'missing secret key');
    ok(!Purl::Storage::S3->config_is_usable(
        { access_key => 'k', secret_key => 's' }), 'missing bucket');
    ok(!Purl::Storage::S3->config_is_usable(undef), 'undef config');
};

done_testing();

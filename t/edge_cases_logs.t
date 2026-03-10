#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Mojo::JSON qw(encode_json);
use Purl::API::Controller::Logs;

# ============================================
# Mock objects (same pattern as t/14_controller_logs.t)
# ============================================
{
    package MockLog;
    sub new { bless {}, $_[0] }
    sub error { }
    sub warn { }

    package MockApp;
    sub new { bless { log => MockLog->new }, $_[0] }
    sub log { $_[0]->{log} }

    package MockResHeaders;
    sub new { bless { h => {} }, $_[0] }
    sub header { $_[0]->{h}{$_[1]} = $_[2] if defined $_[2]; return $_[0]->{h}{$_[1]} }
    sub content_type { $_[0]->{h}{'Content-Type'} = $_[1] if defined $_[1]; $_[0]->{h}{'Content-Type'} }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockReqHeaders;
    sub new { bless { h => $_[1] // {} }, $_[0] }
    sub content_encoding { $_[0]->{h}{'Content-Encoding'} }

    package MockRes;
    sub new { bless { headers => MockResHeaders->new }, $_[0] }
    sub headers { $_[0]->{headers} }

    package MockReq;
    sub new {
        bless {
            body    => $_[1] // '',
            params  => $_[2] // {},
            headers => MockReqHeaders->new($_[3] // {}),
        }, $_[0];
    }
    sub body { $_[0]->{body} }
    sub headers { $_[0]->{headers} }

    package MockCtrl;
    sub new {
        bless {
            req      => MockReq->new($_[1], $_[2], $_[3]),
            res      => MockRes->new,
            rendered => undef,
            stash    => $_[4] // {},
            session  => {},
            params   => $_[2] // {},
            app      => MockApp->new,
        }, $_[0];
    }
    sub req { $_[0]->{req} }
    sub res { $_[0]->{res} }
    sub app { $_[0]->{app} }
    sub param { $_[0]->{params}{$_[1]} }
    sub render {
        my ($self, %args) = @_;
        $self->{rendered} = \%args;
    }
    sub rendered { $_[0]->{rendered} }
    sub stash {
        my ($self, $key, $val) = @_;
        return $self->{stash} unless defined $key;
        $self->{stash}{$key} = $val if defined $val;
        return $self->{stash}{$key};
    }
    sub session {
        my ($self, $key) = @_;
        return $self->{session} unless defined $key;
        return $self->{session}{$key};
    }

    package MockStorage;
    sub new { bless { calls => {} }, $_[0] }
    sub search {
        my ($self, %params) = @_;
        $self->{calls}{search} = \%params;
        return $self->{search_result} // [];
    }
    sub count {
        my ($self, %params) = @_;
        return $self->{count_result} // 0;
    }
    sub insert {
        my ($self, $log) = @_;
        push @{$self->{inserted} //= []}, $log;
    }
    sub flush { $_[0]->{flushed} = 1 }
    sub can { 1 }
    sub field_stats { return [] }
    sub get_context {
        my ($self, $id, %params) = @_;
        return $self->{context_result};
    }
}

# ============================================
# Empty batch ingestion
# ============================================
subtest 'ingest empty JSON array' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json([]);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{status}, 400, 'empty array returns 400';
    like $c->rendered->{json}{error}, qr/Invalid JSON|NDJSON/i, 'error message for empty array';
};

subtest 'ingest empty object (no message)' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({});
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    # Empty object is treated as a single log with defaults
    is $c->rendered->{json}{status}, 'ok', 'empty object ingested with defaults';
    is $c->rendered->{json}{inserted}, 1, '1 log inserted';
    my $log = $storage->{inserted}[0];
    is $log->{level}, 'INFO', 'default level';
    is $log->{service}, 'unknown', 'default service';
    is $log->{message}, '', 'empty message default';
};

# ============================================
# Single log with missing fields (only message)
# ============================================
subtest 'ingest log with only message field' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ message => 'Something happened' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, '1 log inserted';
    my $log = $storage->{inserted}[0];
    is $log->{message}, 'Something happened', 'message preserved';
    is $log->{level}, 'INFO', 'default level INFO';
    is $log->{service}, 'unknown', 'default service unknown';
    is $log->{host}, 'unknown', 'default host unknown';
    ok defined $log->{timestamp}, 'timestamp auto-generated';
    is ref $log->{meta}, 'HASH', 'meta initialized as hash';
};

# ============================================
# Very long messages (>100KB)
# ============================================
subtest 'ingest very long message truncated to 64KB' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $long_msg = 'x' x 100_000;
    my $body = encode_json({ message => $long_msg, level => 'ERROR' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, 'long message log inserted';
    my $log = $storage->{inserted}[0];
    is length($log->{message}), 65536, 'message truncated to 64KB (65536 bytes)';
};

subtest 'ingest very long raw field truncated to 128KB' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $long_raw = 'r' x 200_000;
    my $body = encode_json({ message => 'ok', raw => $long_raw });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, 'long raw log inserted';
    my $log = $storage->{inserted}[0];
    is length($log->{raw}), 131072, 'raw truncated to 128KB (131072 bytes)';
};

# ============================================
# Special characters in service names
# ============================================
subtest 'ingest special chars in service name' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);

    # Service with dots, dashes, underscores (all valid)
    my $body = encode_json({ message => 'test', service => 'my-app.web_v2' });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $storage->{inserted}[0]{service}, 'my-app.web_v2', 'dots/dashes/underscores preserved';
};

subtest 'ingest service name truncation at 256 chars' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $long_svc = 'a' x 300;
    my $body = encode_json({ message => 'test', service => $long_svc });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is length($storage->{inserted}[0]{service}), 256, 'service truncated to 256';
};

subtest 'ingest host name truncation at 256 chars' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $long_host = 'h' x 300;
    my $body = encode_json({ message => 'test', host => $long_host });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is length($storage->{inserted}[0]{host}), 256, 'host truncated to 256';
};

# ============================================
# Unicode in messages
# ============================================
subtest 'ingest unicode messages' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);

    # Emoji
    my $body = encode_json({ message => "Server crashed \x{1F4A5}", level => 'ERROR' });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    like $storage->{inserted}[0]{message}, qr/Server crashed/, 'emoji message ingested';

    # CJK
    $storage = MockStorage->new;
    $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    $body = encode_json({ message => "\x{30A8}\x{30E9}\x{30FC}\x{304C}\x{767A}\x{751F}" });
    $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, 'CJK message ingested';
};

# ============================================
# Null bytes in raw data
# ============================================
subtest 'ingest with null bytes in message' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    # JSON cannot contain literal null bytes, but the message field could have escaped ones
    my $body = encode_json({ message => "before\\x00after", level => 'INFO' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, 'message with escaped null bytes ingested';
};

# ============================================
# Invalid timestamp formats
# ============================================
subtest 'ingest with various timestamp formats' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);

    # Valid ISO timestamp - should be preserved
    my $body = encode_json({ message => 'test', timestamp => '2025-01-15T10:30:00.000Z' });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $storage->{inserted}[0]{timestamp}, '2025-01-15T10:30:00.000Z', 'ISO timestamp preserved';

    # Invalid timestamp string - still stored (no validation on timestamp format in ingest)
    $storage = MockStorage->new;
    $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    $body = encode_json({ message => 'test', timestamp => 'not-a-timestamp' });
    $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $storage->{inserted}[0]{timestamp}, 'not-a-timestamp', 'invalid timestamp passed through';
};

# ============================================
# Duplicate log entries
# ============================================
subtest 'ingest duplicate log entries' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $log = { message => 'duplicate entry', level => 'WARN', service => 'api' };
    my $body = encode_json([$log, $log, $log]);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 3, 'all duplicates inserted (no dedup at ingest)';
    is scalar @{$storage->{inserted}}, 3, 'storage received 3 logs';
};

# ============================================
# Maximum field length boundaries
# ============================================
subtest 'level field maximum length (32 chars)' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);

    # Exactly 32 chars - should be accepted
    my $level_32 = 'A' x 32;
    my $body = encode_json({ message => 'test', level => $level_32 });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 1, '32-char level accepted';

    # 33 chars - should be rejected
    $storage = MockStorage->new;
    $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $level_33 = 'A' x 33;
    $body = encode_json({ message => 'test', level => $level_33 });
    $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is $c->rendered->{status}, 400, '33-char level rejected with 400';
};

# ============================================
# Batch size limit
# ============================================
subtest 'ingest batch exceeding 10000 limit' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my @logs = map { { message => "log $_" } } 1..10_001;
    my $body = encode_json(\@logs);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{status}, 400, 'batch >10000 returns 400';
    like $c->rendered->{json}{error}, qr/Batch too large/, 'error mentions batch limit';
};

subtest 'ingest batch exactly at 10000 limit' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my @logs = map { { message => "log $_" } } 1..10_000;
    my $body = encode_json(\@logs);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{status}, 'ok', 'batch at exactly 10000 accepted';
    is $c->rendered->{json}{inserted}, 10_000, '10000 logs inserted';
};

# ============================================
# Meta field as non-hash gets reset
# ============================================
subtest 'ingest with non-hash meta field' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);

    # meta as string
    my $body = encode_json({ message => 'test', meta => 'not a hash' });
    my $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is ref $storage->{inserted}[0]{meta}, 'HASH', 'string meta converted to hash';

    # meta as array
    $storage = MockStorage->new;
    $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    $body = encode_json({ message => 'test', meta => [1, 2, 3] });
    $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is ref $storage->{inserted}[0]{meta}, 'HASH', 'array meta converted to hash';

    # meta as number
    $storage = MockStorage->new;
    $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    $body = encode_json({ message => 'test', meta => 42 });
    $c = MockCtrl->new($body);
    $ctrl->ingest($c);
    is ref $storage->{inserted}[0]{meta}, 'HASH', 'number meta converted to hash';
};

# ============================================
# Alternative message field names
# ============================================
subtest 'ingest with msg field alias' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ msg => 'via msg field' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $storage->{inserted}[0]{message}, 'via msg field', 'msg alias resolved to message';
};

subtest 'ingest with log field alias' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = encode_json({ log => 'via log field' });
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $storage->{inserted}[0]{message}, 'via log field', 'log alias resolved to message';
};

# ============================================
# NDJSON edge cases
# ============================================
subtest 'ingest NDJSON with blank lines' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = qq({"message":"line1"}\n\n\n{"message":"line2"}\n\n);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 2, 'blank lines in NDJSON skipped';
};

subtest 'ingest NDJSON with invalid lines mixed in' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $body = qq({"message":"valid1"}\nnot json\n{"message":"valid2"}\n);
    my $c = MockCtrl->new($body);

    $ctrl->ingest($c);
    is $c->rendered->{json}{inserted}, 2, 'invalid NDJSON lines skipped, valid ones ingested';
};

# ============================================
# Invalid JSON body
# ============================================
subtest 'ingest completely invalid body' => sub {
    my $storage = MockStorage->new;
    my $ctrl = Purl::API::Controller::Logs->new(storage => $storage);
    my $c = MockCtrl->new('this is not json at all!!!');

    $ctrl->ingest($c);
    is $c->rendered->{status}, 400, 'non-JSON body returns 400';
};

done_testing;

package Purl::API::Controller::Syslog;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);
use Purl::Util::Time qw(epoch_to_iso);

extends 'Purl::API::Controller::Base';

# ============================================
# Syslog ingest endpoint
# Accepts RFC 5424 and RFC 3164 syslog messages
# via HTTP POST for easy integration.
# ============================================

# RFC 5424 severity levels mapped to Purl levels
my %SEVERITY_MAP = (
    0 => 'EMERGENCY',
    1 => 'ALERT',
    2 => 'CRITICAL',
    3 => 'ERROR',
    4 => 'WARNING',
    5 => 'NOTICE',
    6 => 'INFO',
    7 => 'DEBUG',
);

# RFC 5424 facility names
my @FACILITY_NAMES = qw(
    kern user mail daemon auth syslog lpr news
    uucp cron authpriv ftp ntp security console solaris-cron
    local0 local1 local2 local3 local4 local5 local6 local7
);

sub ingest {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $content_type = $c->req->headers->content_type // '';
        my $body = $c->req->body;

        unless ($body && length($body) > 0) {
            $self->render_error($c, 'Empty request body', 400);
            return;
        }

        my @logs;

        if ($content_type =~ /json/i) {
            # JSON payload: { "messages": ["<PRI>..."] } or { "message": "<PRI>..." }
            my $data = eval { decode_json($body) };
            unless ($data) {
                $self->render_error($c, 'Invalid JSON payload', 400);
                return;
            }

            my $messages = $data->{messages} // ($data->{message} ? [$data->{message}] : []);
            unless (ref $messages eq 'ARRAY' && @$messages) {
                $self->render_error($c, 'No syslog messages found in payload', 400);
                return;
            }

            for my $msg (@$messages) {
                my $parsed = _parse_syslog($msg);
                push @logs, $parsed if $parsed;
            }
        } else {
            # Plain text: one syslog message per line
            my @lines = split /\n/, $body;
            for my $line (@lines) {
                next unless $line =~ /\S/;
                my $parsed = _parse_syslog($line);
                push @logs, $parsed if $parsed;
            }
        }

        unless (@logs) {
            $self->render_error($c, 'No valid syslog messages could be parsed', 400);
            return;
        }

        if (scalar(@logs) > 10_000) {
            $self->render_error($c, 'Batch too large: maximum 10000 messages per request', 400);
            return;
        }

        # Run logs through configured pipelines (enrich / rewrite / drop)
        # before storage. No-op unless pipelines are configured.
        @logs = @{ $self->apply_pipelines($c, \@logs) };

        my $count = 0;
        for my $log (@logs) {
            # Field length limits
            if (defined $log->{message} && length($log->{message}) > 65536) {
                $log->{message} = substr($log->{message}, 0, 65536);
            }
            if (defined $log->{service} && length($log->{service}) > 256) {
                $log->{service} = substr($log->{service}, 0, 256);
            }
            if (defined $log->{host} && length($log->{host}) > 256) {
                $log->{host} = substr($log->{host}, 0, 256);
            }

            $self->storage->insert($log);
            $count++;
        }

        $self->storage->flush() if $self->storage->can('flush');

        $c->render(json => {
            status   => 'ok',
            inserted => $count,
        });
    });
}

# ============================================
# Syslog parsing
# ============================================

sub _parse_syslog {
    my ($raw) = @_;
    return undef unless defined $raw && length($raw) > 0;

    # Try RFC 5424 first, then fall back to RFC 3164
    my $parsed = _parse_rfc5424($raw) // _parse_rfc3164($raw);
    return undef unless $parsed;

    $parsed->{raw} = $raw;
    return $parsed;
}

# RFC 5424: <PRI>VERSION TIMESTAMP HOSTNAME APP-NAME PROCID MSGID [SD] MSG
sub _parse_rfc5424 {
    my ($raw) = @_;

    # Match RFC 5424 format
    my $re = qr{
        ^<(\d{1,3})>                      # PRI
        (\d+)\s+                           # VERSION
        (\S+)\s+                           # TIMESTAMP
        (\S+)\s+                           # HOSTNAME
        (\S+)\s+                           # APP-NAME
        (\S+)\s+                           # PROCID
        (\S+)\s+                           # MSGID
        (?:(\[.*?\])\s*)?                  # STRUCTURED-DATA (optional)
        (.*)                               # MSG
    }sx;

    return undef unless $raw =~ $re;

    my ($pri, $version, $ts, $hostname, $app_name, $procid, $msgid, $sd, $msg) =
        ($1, $2, $3, $4, $5, $6, $7, $8, $9);

    my ($facility, $severity) = _decode_pri($pri);

    # Parse structured data into meta
    my $meta = {};
    if ($sd && $sd ne '-') {
        $meta = _parse_structured_data($sd);
    }

    $meta->{facility}  = $FACILITY_NAMES[$facility] // "facility$facility";
    $meta->{severity}  = $severity;
    $meta->{procid}    = $procid   if $procid ne '-';
    $meta->{msgid}     = $msgid    if $msgid ne '-';
    $meta->{syslog_version} = $version;

    my $timestamp = _parse_syslog_timestamp($ts);

    return {
        timestamp => $timestamp,
        level     => $SEVERITY_MAP{$severity} // 'INFO',
        service   => $app_name eq '-' ? 'syslog' : $app_name,
        host      => $hostname eq '-' ? 'unknown' : $hostname,
        message   => $msg // '',
        meta      => $meta,
    };
}

# RFC 3164 (BSD): <PRI>TIMESTAMP HOSTNAME APP-NAME[PID]: MSG
sub _parse_rfc3164 {
    my ($raw) = @_;

    # Match RFC 3164 format
    my $re = qr{
        ^<(\d{1,3})>                       # PRI
        (\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})\s+  # TIMESTAMP (Mon DD HH:MM:SS)
        (\S+)\s+                           # HOSTNAME
        (\S+?)                             # APP-NAME
        (?:\[(\d+)\])?                     # PID (optional)
        :\s*                               # Separator
        (.*)                               # MSG
    }sx;

    return undef unless $raw =~ $re;

    my ($pri, $ts, $hostname, $app_name, $pid, $msg) = ($1, $2, $3, $4, $5, $6);
    my ($facility, $severity) = _decode_pri($pri);

    my $meta = {
        facility => $FACILITY_NAMES[$facility] // "facility$facility",
        severity => $severity,
    };
    $meta->{pid} = $pid if $pid;

    my $timestamp = _parse_bsd_timestamp($ts);

    return {
        timestamp => $timestamp,
        level     => $SEVERITY_MAP{$severity} // 'INFO',
        service   => $app_name // 'syslog',
        host      => $hostname // 'unknown',
        message   => $msg // '',
        meta      => $meta,
    };
}

sub _decode_pri {
    my ($pri) = @_;
    $pri = int($pri);
    my $facility = int($pri / 8);
    my $severity = $pri % 8;
    return ($facility, $severity);
}

sub _parse_structured_data {
    my ($sd) = @_;
    my %meta;

    # Parse [sdId param="value" param="value"]
    while ($sd =~ /\[(\S+?)\s+(.*?)\]/g) {
        my ($sd_id, $params_str) = ($1, $2);
        while ($params_str =~ /(\w+)="((?:[^"\\]|\\.)*)"/g) {
            my ($key, $val) = ($1, $2);
            $val =~ s/\\(.)/$1/g;  # Unescape
            $meta{"${sd_id}.${key}"} = $val;
        }
    }

    return \%meta;
}

sub _parse_syslog_timestamp {
    my ($ts) = @_;
    return epoch_to_iso(time()) if !$ts || $ts eq '-';

    # ISO 8601 format (RFC 5424)
    if ($ts =~ /^\d{4}-\d{2}-\d{2}T/) {
        $ts =~ s/Z$//;
        $ts =~ s/\+\d{2}:\d{2}$//;
        return $ts . 'Z' unless $ts =~ /Z$/;
        return $ts;
    }

    return epoch_to_iso(time());
}

sub _parse_bsd_timestamp {
    my ($ts) = @_;
    return epoch_to_iso(time()) unless $ts;

    # BSD format: "Mon DD HH:MM:SS" — add current year
    my @t = localtime();
    my $year = $t[5] + 1900;
    my %months = (
        Jan => '01', Feb => '02', Mar => '03', Apr => '04',
        May => '05', Jun => '06', Jul => '07', Aug => '08',
        Sep => '09', Oct => '10', Nov => '11', Dec => '12',
    );

    if ($ts =~ /^(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})$/) {
        my ($mon, $day, $h, $m, $s) = ($1, $2, $3, $4, $5);
        my $month = $months{$mon} // '01';
        return sprintf('%04d-%s-%02dT%s:%s:%sZ', $year, $month, $day, $h, $m, $s);
    }

    return epoch_to_iso(time());
}

1;

__END__

=head1 NAME

Purl::API::Controller::Syslog - RFC 5424/3164 syslog ingest via HTTP

=head1 DESCRIPTION

Accepts syslog messages via HTTP POST and converts them to Purl's
internal log format. Supports both RFC 5424 and RFC 3164 formats.

Endpoint: POST /api/v1/syslog

Accepts:
    Content-Type: text/plain — one syslog message per line
    Content-Type: application/json — { "messages": ["<PRI>..."] }

=cut

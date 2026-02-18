package Purl::API::Controller::K8sAudit;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);
use Time::HiRes qw(time);

extends 'Purl::API::Controller::Base';

# ============================================
# Kubernetes API audit log webhook receiver
# Accepts K8s audit.k8s.io/v1 events and converts
# to Purl internal log format.
# ============================================

# Map K8s audit levels to Purl log levels
my %LEVEL_MAP = (
    'Metadata'        => 'INFO',
    'Request'         => 'INFO',
    'RequestResponse' => 'DEBUG',
    'None'            => 'DEBUG',
);

sub ingest {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        # K8s sends EventList with items array
        my $items = $body->{items} // [$body];
        unless (ref $items eq 'ARRAY') {
            $self->render_error($c, 'Invalid audit format', 400);
            return;
        }

        my @logs;
        my $now_iso = _now_iso();

        for my $event (@$items) {
            next unless $event->{verb};

            my $obj_ref   = $event->{objectRef} // {};
            my $user      = $event->{user} // {};
            my $resource  = $obj_ref->{resource} // '';
            my $name      = $obj_ref->{name} // '';
            my $namespace = $obj_ref->{namespace} // '';
            my $verb      = $event->{verb} // '';
            my $username  = $user->{username} // '';
            my $level     = $event->{level} // 'Metadata';
            my $stage_ts  = $event->{stageTimestamp} // $event->{requestReceivedTimestamp} // $now_iso;

            my $message = "$verb $resource";
            $message .= "/$name" if $name;
            $message .= " by $username" if $username;

            my $meta = encode_json({
                namespace => $namespace,
                user      => $username,
                verb      => $verb,
                resource  => $resource,
                name      => $name,
                source    => 'k8s-audit',
                api_group => $obj_ref->{apiGroup} // '',
                status    => $event->{responseStatus}{code} // 0,
            });

            push @logs, {
                timestamp  => $stage_ts,
                level      => $LEVEL_MAP{$level} // 'INFO',
                service    => 'k8s-audit',
                host       => $event->{sourceIPs}[0] // '',
                message    => $message,
                raw        => encode_json($event),
                meta       => $meta,
                trace_id   => $event->{auditID} // '',
                request_id => $event->{auditID} // '',
                span_id    => '',
                parent_span_id => '',
            };
        }

        if (@logs) {
            $self->storage->store_batch(\@logs);
        }

        $c->render(json => {
            accepted => scalar @logs,
            message  => 'Audit events ingested',
        });
    });
}

sub _now_iso {
    my @t = gmtime(time());
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

1;

__END__

=head1 NAME

Purl::API::Controller::K8sAudit - Kubernetes API audit webhook receiver

=head1 DESCRIPTION

Receives K8s audit.k8s.io/v1 events via webhook and stores them as logs.

Endpoints:
    POST /api/v1/k8s-audit - Receive audit events

=cut

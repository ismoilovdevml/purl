package Purl::API::Controller::Pipeline;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json encode_json);

use Purl::Pipeline::Engine;

extends 'Purl::API::Controller::Base';

# ============================================
# Pipeline management API controller
# ============================================

has 'engine' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my ($self) = @_;
        # ReDoS guard bounds (mirror Config pipeline.* defaults). Read
        # from the injected config hashref when present, else default.
        my $pcfg = (ref $self->config eq 'HASH')
            ? ($self->config->{pipeline} // {})
            : {};
        return Purl::Pipeline::Engine->new(
            regex_timeout_ms => $pcfg->{regex_timeout_ms} // 250,
            regex_max_length => $pcfg->{regex_max_length} // 512,
        );
    },
);

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');

        my $pipelines = $self->storage->list_pipelines();
        $c->render(json => { pipelines => $pipelines });
    });
}

sub get {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid pipeline ID', 400);
            return;
        }

        my $pipeline = $self->storage->get_pipeline($id);
        unless ($pipeline) {
            $self->render_error($c, 'Pipeline not found', 404);
            return;
        }

        $c->render(json => $pipeline);
    });
}

sub create {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');
        return unless $self->require_role($c, 'admin', 'operator');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        unless ($body->{name} && length($body->{name}) > 0) {
            $self->render_error($c, 'Pipeline name is required', 400);
            return;
        }

        # Validate rules
        if ($body->{rules}) {
            unless (ref $body->{rules} eq 'ARRAY') {
                $self->render_error($c, 'Rules must be an array', 400);
                return;
            }
            for my $rule (@{ $body->{rules} }) {
                unless ($rule->{type} && $rule->{type} =~ /^(regex|json_extract|drop|mutate|grok)$/) {
                    $self->render_error($c, "Invalid rule type: $rule->{type}", 400);
                    return;
                }
            }
        }

        my $result = $self->storage->create_pipeline($body);
        $c->render(json => $result, status => 201);
    });
}

sub update {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');
        return unless $self->require_role($c, 'admin', 'operator');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid pipeline ID', 400);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $result = $self->storage->update_pipeline($id, $body);
        unless ($result) {
            $self->render_error($c, 'Pipeline not found', 404);
            return;
        }

        $c->render(json => $result);
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');
        return unless $self->require_role($c, 'admin');

        my $id = $c->param('id');
        unless ($id && $id =~ /^[0-9a-f-]+$/i) {
            $self->render_error($c, 'Invalid pipeline ID', 400);
            return;
        }

        my $result = $self->storage->delete_pipeline($id);
        $c->render(json => $result);
    });
}

sub test {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'pipelines');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON payload', 400);
            return;
        }

        my $pipeline = $body->{pipeline};
        my $samples  = $body->{samples};

        unless ($pipeline && ref $pipeline eq 'HASH') {
            $self->render_error($c, 'Pipeline configuration required', 400);
            return;
        }
        unless ($samples && ref $samples eq 'ARRAY' && @$samples) {
            $self->render_error($c, 'Sample log entries required', 400);
            return;
        }

        # Limit samples
        splice @$samples, 10 if @$samples > 10;

        my $results = $self->engine->test_pipeline($pipeline, $samples);
        $c->render(json => { results => $results });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Pipeline - Log pipeline management API

=head1 DESCRIPTION

CRUD operations for log processing pipelines. Pipelines define
ordered rules that transform log entries during ingestion.

Endpoints:
    GET    /api/pipelines         - List all pipelines
    GET    /api/pipelines/:id     - Get pipeline details
    POST   /api/pipelines         - Create pipeline
    PUT    /api/pipelines/:id     - Update pipeline
    DELETE /api/pipelines/:id     - Delete pipeline
    POST   /api/pipelines/test    - Test pipeline against samples

=cut

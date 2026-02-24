package Purl::API::Controller::Agents;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();

extends 'Purl::API::Controller::Base';

my $json = JSON::XS->new->utf8;

sub list {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $agents = $self->storage->get_agents() // [];
        my $total  = scalar @$agents;

        my $info = $c->stash('license_info') // {};
        my $max  = $info->{limits}{agents} // 5;
        my $plan = $info->{plan} // 'free';

        $c->render(json => {
            agents => $agents,
            total  => $total,
            limit  => {
                current => $total,
                max     => $max,
                plan    => $plan,
            },
        });
    });
}

sub register {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { $json->decode($c->req->body) } // {};

        my $hostname = $body->{hostname} // '';
        unless ($hostname) {
            $self->render_error($c, 'hostname is required', 400);
            return;
        }

        # Check agent limit
        my $current_count = $self->storage->count_agents();
        return unless $self->check_limit($c, 'agents', $current_count);

        my $labels = '';
        if (ref $body->{labels} eq 'HASH') {
            $labels = eval { $json->encode($body->{labels}) } // '{}';
        }

        $self->storage->register_agent({
            hostname      => $hostname,
            os            => $body->{os}            // '',
            ip_address    => $body->{ip_address}    // '',
            agent_version => $body->{agent_version} // '',
            api_key_label => $body->{api_key_label} // '',
            labels        => $labels,
        });

        $c->render(json => {
            status  => 'ok',
            message => 'Agent registered successfully',
        });
    });
}

sub heartbeat {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { $json->decode($c->req->body) } // {};

        my $hostname = $body->{hostname} // '';
        unless ($hostname) {
            $self->render_error($c, 'hostname is required', 400);
            return;
        }

        $self->storage->heartbeat_agent({
            hostname      => $hostname,
            ip_address    => $body->{ip_address}    // '',
            agent_version => $body->{agent_version} // '',
        });

        $c->render(json => {
            status  => 'ok',
            message => 'Heartbeat received',
        });
    });
}

sub remove {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $id = $c->param('id') // '';
        unless ($id) {
            $self->render_error($c, 'Agent ID is required', 400);
            return;
        }

        $self->storage->delete_agent($id);

        $c->render(json => {
            status  => 'ok',
            message => 'Agent removed',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Agents - Agent management REST endpoints

=head1 DESCRIPTION

GET    /api/agents           - List all registered agents with status
POST   /api/agents/register  - Register a new agent (API key auth)
POST   /api/agents/heartbeat - Agent heartbeat update (API key auth)
DELETE /api/agents/:id       - Remove an agent record (admin only)

=cut

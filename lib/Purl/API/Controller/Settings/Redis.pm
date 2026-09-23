package Purl::API::Controller::Settings::Redis;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use Mojo::JSON qw(decode_json);

extends 'Purl::API::Controller::Base';

# Settings manager (Purl::Config instance)
has 'settings' => (
    is       => 'ro',
    required => 1,
);

# ============================================
# Redis / Broadcast settings
# ============================================

sub get_redis {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $redis = $self->settings->get_section('redis') // {};

        $c->render(json => {
            config   => $redis,
            from_env => $self->env_flags('redis'),
        });
    });
}

sub update_redis {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # See Settings::AI::update_ai: skipping an ENV-owned key and still
        # reporting 'ok' is exactly the lie #53 is about. Guard before
        # validation — see Settings::LDAP::update_ldap.
        return if $self->reject_env_managed($c, 'redis', $body);

        my %valid_modes = map { $_ => 1 } qw(auto local redis);
        if (exists $body->{mode} && !$valid_modes{ $body->{mode} }) {
            $self->render_error($c, 'Invalid mode. Allowed: auto, local, redis', 400);
            return;
        }

        my $current = $self->settings->get_section('redis') // {};

        for my $key (qw(url mode)) {
            next unless exists $body->{$key};
            $current->{$key} = $body->{$key};
        }

        if ($self->settings->set_section('redis', $current)) {
            $c->audit_event(action => 'update_settings', resource_type => 'settings', resource_id => 'redis');
            $c->render(json => { status => 'ok', message => 'Redis settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save Redis settings', 500);
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::Redis - Redis / broadcast settings

=cut

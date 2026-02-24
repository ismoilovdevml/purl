package Purl::API::Controller::Base;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;

has 'storage' => (
    is       => 'ro',
    required => 1,
);

has 'config' => (
    is => 'ro',
    default => sub { {} },
);

has 'cache' => (
    is => 'rw',
    default => sub { {} },
);

has 'namespace_scope' => (
    is      => 'ro',
    default => sub { undef },
);

sub get_cached {
    my ($self, $key) = @_;
    my $entry = $self->cache->{$key};
    return unless $entry;
    return if $entry->{expires} < time();
    return $entry->{value};
}

sub set_cached {
    my ($self, $key, $value, $ttl) = @_;
    $ttl //= 60;
    $self->cache->{$key} = {
        value   => $value,
        expires => time() + $ttl,
    };
    return $value;
}

sub render_error {
    my ($self, $c, $message, $code) = @_;
    $code //= 500;
    
    # Log the error if it's a 500
    if ($code >= 500) {
        $c->app->log->error($message);
    }
    
    $c->render(json => { error => $message }, status => $code);
}

sub safe_execute {
    my ($self, $c, $cb) = @_;

    eval {
        $cb->();
    };
    if ($@) {
        $self->render_error($c, "Internal Server Error: $@", 500);
    }
}

# ============================================
# License enforcement helpers
# ============================================

sub require_feature {
    my ($self, $c, $feature) = @_;
    my $info = $c->stash('license_info') // return 1;
    my $plan = $info->{plan} // 'free';

    # Enterprise plan has access to all features
    return 1 if $plan eq 'enterprise';

    my @features = @{ $info->{features} // [] };
    return 1 if grep { $_ eq $feature } @features;
    $c->render(json => {
        error   => "This feature requires a Pro or Enterprise license",
        feature => $feature,
        plan    => $plan,
        upgrade => 'https://purlogs.com/pricing',
    }, status => 403);
    return 0;
}

sub check_limit {
    my ($self, $c, $limit_name, $current_count) = @_;
    my $info = $c->stash('license_info') // return 1;
    my $max = $info->{limits}{$limit_name} // return 1;
    return 1 if $max < 0;  # -1 means unlimited (Enterprise)
    return 1 if $current_count < $max;
    my $plan = $info->{plan} // 'free';
    $c->render(json => {
        error   => "Limit reached: $limit_name (current: $current_count, max: $max)",
        plan    => $plan,
        upgrade => 'https://purlogs.com/pricing',
    }, status => 403);
    return 0;
}

# ============================================
# RBAC helpers
# ============================================

sub require_role {
    my ($self, $c, @allowed_roles) = @_;
    my $role = $c->session('role') // 'viewer';
    return 1 if $role eq 'admin';
    return 1 if grep { $_ eq $role } @allowed_roles;
    $self->render_error($c, 'Insufficient permissions', 403);
    return 0;
}

1;

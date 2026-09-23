package Purl::API::Controller::Settings::ApiKeys;
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

# Auth middleware for user management
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

# ============================================
# API Key Rotation
# ============================================

sub list_api_keys {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        my $auth_config = $self->settings->get_section('auth') // {};
        my $api_keys = $auth_config->{api_keys} // [];
        $api_keys = [split /,/, $api_keys] if !ref $api_keys;

        my @masked;
        for my $entry (@$api_keys) {
            if (ref $entry eq 'HASH') {
                my $key = $entry->{key} // '';
                push @masked, {
                    id         => substr($key, 0, 8),
                    masked_key => _mask_key($key),
                    label      => $entry->{label} // '',
                    created_at => $entry->{created_at} // '',
                };
            } else {
                # Legacy plain string key
                push @masked, {
                    id         => substr($entry, 0, 8),
                    masked_key => _mask_key($entry),
                    label      => '',
                    created_at => '',
                };
            }
        }

        $c->render(json => {
            api_keys => \@masked,
            from_env => $self->settings->is_from_env('auth', 'api_keys') ? 1 : 0,
        });
    });
}

sub generate_api_key {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        # 409, not 400: the request is well-formed, the RESOURCE is owned by the
        # environment. PURL_API_KEYS wins on every read, so a key minted here
        # would be written to settings.json and never authenticate — a 200 that
        # hands the admin a dead key is worse than a refusal.
        if ($self->settings->is_from_env('auth', 'api_keys')) {
            $c->render(json => {
                error    => 'Cannot modify - API keys configured via PURL_API_KEYS',
                from_env => 1,
            }, status => 409);
            return;
        }

        my $body = eval { decode_json($c->req->body) };
        my $label = ($body && $body->{label}) ? $body->{label} : '';

        # Validate label if provided
        if ($label && $label !~ /^[\w\s\-\.]{1,64}$/) {
            $self->render_error($c, 'Label must be 1-64 alphanumeric characters, spaces, hyphens, dots', 400);
            return;
        }

        # Generate secure 48-char API key
        my $new_key = join '', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..48;

        my ($sec, $min, $hour, $mday, $mon, $year) = gmtime(time);
        my $created_at = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
            $year + 1900, $mon + 1, $mday, $hour, $min, $sec);

        # The whole read-modify-write happens inside update_section. Doing it
        # by hand around set_section drops anything another worker committed to
        # the auth section meanwhile — another admin's key, or a new user.
        my $saved = $self->settings->update_section('auth', sub {
            my ($auth_config) = @_;

            my $api_keys = $auth_config->{api_keys} // [];
            $api_keys = [split /,/, $api_keys] if !ref $api_keys;

            # Ensure all entries are hash format
            my @normalized;
            for my $entry (@$api_keys) {
                if (ref $entry eq 'HASH') {
                    push @normalized, $entry;
                } else {
                    push @normalized, { key => $entry, label => '', created_at => '' };
                }
            }

            push @normalized, {
                key        => $new_key,
                label      => $label,
                created_at => $created_at,
            };

            $auth_config->{api_keys} = \@normalized;
        });

        if ($saved) {
            # Reload keys in auth middleware
            $self->auth_middleware->reload_api_keys() if $self->auth_middleware;
            # The listing id (first 8 chars), never the key itself.
            $c->audit_event(action => 'generate_api_key', resource_type => 'api_key',
                resource_id => substr($new_key, 0, 8), details => $label);

            $c->render(json => {
                status     => 'ok',
                api_key    => $new_key,
                label      => $label,
                created_at => $created_at,
                message    => 'API key generated. Store it securely — it will not be shown again.',
            });
        } else {
            $self->render_error($c, 'Failed to save API key', 500);
        }
    });
}

sub revoke_api_key {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_role($c, 'admin');

        # 409 — see generate_api_key. Revoking a key the environment supplies
        # cannot work: ENV wins on read, so the key would keep authenticating
        # while the UI showed it as gone.
        if ($self->settings->is_from_env('auth', 'api_keys')) {
            $c->render(json => {
                error    => 'Cannot modify - API keys configured via PURL_API_KEYS',
                from_env => 1,
            }, status => 409);
            return;
        }

        my $key_id = $c->param('key_id');
        unless ($key_id && length($key_id) >= 1) {
            $self->render_error($c, 'Key identifier required', 400);
            return;
        }

        # Match and remove inside the lock, against the newest revision — the
        # list read outside one may already be missing a key another admin
        # added, and writing it back would revoke that key too.
        my $found = 0;
        my $saved = $self->settings->update_section('auth', sub {
            my ($auth_config, $cancel) = @_;

            my $api_keys = $auth_config->{api_keys} // [];
            $api_keys = [split /,/, $api_keys] if !ref $api_keys;

            my @remaining;
            for my $entry (@$api_keys) {
                my $key   = ref $entry eq 'HASH' ? ($entry->{key} // '') : $entry;
                my $label = ref $entry eq 'HASH' ? ($entry->{label} // '') : '';

                # Match by prefix (first 8 chars) or by label
                if (substr($key, 0, 8) eq $key_id || ($label ne '' && $label eq $key_id)) {
                    $found = 1;
                    next;
                }
                push @remaining, $entry;
            }

            # Nothing matched: leave the file alone. A 404 that still rewrites
            # settings.json is a write nobody asked for.
            return $cancel->() unless $found;

            $auth_config->{api_keys} = \@remaining;
        });

        unless ($found) {
            $self->render_error($c, 'API key not found', 404);
            return;
        }

        if ($saved) {
            # Reload keys in auth middleware
            $self->auth_middleware->reload_api_keys() if $self->auth_middleware;
            $c->audit_event(action => 'revoke_api_key', resource_type => 'api_key',
                resource_id => $key_id);

            $c->render(json => {
                status  => 'ok',
                message => 'API key revoked.',
            });
        } else {
            $self->render_error($c, 'Failed to revoke API key', 500);
        }
    });
}

sub _mask_key {
    my ($key) = @_;
    return '' unless defined $key && length($key) >= 12;
    return substr($key, 0, 8) . '...' . substr($key, -4);
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings::ApiKeys - ingest API key listing, generation and revocation

=cut

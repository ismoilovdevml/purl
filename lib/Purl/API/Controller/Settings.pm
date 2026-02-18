package Purl::API::Controller::Settings;
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

# Notifiers hash reference for test notifications
has 'notifiers' => (
    is      => 'ro',
    default => sub { {} },
);

# Callback to rebuild notifiers after settings change
has 'rebuild_notifiers' => (
    is      => 'ro',
    default => sub { sub {} },
);

# Callback to rebuild storage after settings change
has 'rebuild_storage' => (
    is      => 'ro',
    default => sub { sub {} },
);

# Callback to reload license after key change
has 'reload_license' => (
    is      => 'ro',
    default => sub { sub {} },
);

# Callback to rebuild LDAP middleware after config change
has 'rebuild_ldap' => (
    is      => 'ro',
    default => sub { sub {} },
);

# LDAP middleware for test connection
has 'ldap_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

has 'saml_middleware' => (
    is      => 'rw',
    default => sub { undef },
);

has 'rebuild_saml' => (
    is      => 'ro',
    default => sub { sub {} },
);

# Auth middleware for user management
has 'auth_middleware' => (
    is      => 'ro',
    default => sub { undef },
);

sub get_all {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $all = $self->settings->get_all();

        my $result = {
            clickhouse => {
                host     => { value => $all->{clickhouse}{host}, from_env => $self->settings->is_from_env('clickhouse', 'host') },
                port     => { value => $all->{clickhouse}{port}, from_env => $self->settings->is_from_env('clickhouse', 'port') },
                database => { value => $all->{clickhouse}{database}, from_env => $self->settings->is_from_env('clickhouse', 'database') },
                user     => { value => $all->{clickhouse}{user}, from_env => $self->settings->is_from_env('clickhouse', 'user') },
                password_set => { value => ($all->{clickhouse}{password} ? 1 : 0), from_env => $self->settings->is_from_env('clickhouse', 'password') },
            },
            retention => {
                days => { value => $all->{retention}{days}, from_env => $self->settings->is_from_env('retention', 'days') },
            },
            auth => {
                enabled => { value => $all->{auth}{enabled}, from_env => $self->settings->is_from_env('auth', 'enabled') },
            },
            notifications => {
                telegram => {
                    enabled   => $self->settings->get_nested('notifications', 'telegram', 'enabled') // 0,
                    bot_token => $self->settings->get_nested('notifications', 'telegram', 'bot_token') ? 1 : 0,
                    chat_id   => $self->settings->get_nested('notifications', 'telegram', 'chat_id') ? 1 : 0,
                    from_env  => $ENV{PURL_TELEGRAM_BOT_TOKEN} ? 1 : 0,
                },
                slack => {
                    enabled     => $self->settings->get_nested('notifications', 'slack', 'enabled') // 0,
                    webhook_set => $self->settings->get_nested('notifications', 'slack', 'webhook_url') ? 1 : 0,
                    channel     => $self->settings->get_nested('notifications', 'slack', 'channel') // '',
                    from_env    => $ENV{PURL_SLACK_WEBHOOK_URL} ? 1 : 0,
                },
                webhook => {
                    enabled  => $self->settings->get_nested('notifications', 'webhook', 'enabled') // 0,
                    url_set  => $self->settings->get_nested('notifications', 'webhook', 'url') ? 1 : 0,
                    from_env => $ENV{PURL_ALERT_WEBHOOK_URL} ? 1 : 0,
                },
            },
        };

        $c->render(json => $result);
    });
}

sub update_clickhouse {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Check which fields are from ENV (cannot modify)
        my @from_env;
        for my $key (qw(host port database user password)) {
            if ($self->settings->is_from_env('clickhouse', $key) && exists $body->{$key}) {
                push @from_env, $key;
            }
        }

        if (@from_env) {
            $c->render(json => {
                error    => "Cannot modify ENV-configured values: " . join(', ', @from_env),
                from_env => \@from_env,
            }, status => 400);
            return;
        }

        # Update settings
        my $current = $self->settings->get_section('clickhouse');
        for my $key (qw(host port database user password)) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        if ($self->settings->set_section('clickhouse', $current)) {
            # Rebuild storage with new settings
            $self->rebuild_storage->();

            $c->render(json => {
                status  => 'ok',
                message => 'ClickHouse settings updated. Restart may be required for full effect.',
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub update_notifications {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type');
        my $body = eval { decode_json($c->req->body) };

        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $self->render_error($c, 'Invalid notification type', 400);
            return;
        }

        # Check ENV override
        my %env_check = (
            telegram => 'PURL_TELEGRAM_BOT_TOKEN',
            slack    => 'PURL_SLACK_WEBHOOK_URL',
            webhook  => 'PURL_ALERT_WEBHOOK_URL',
        );

        if ($ENV{$env_check{$type}}) {
            $c->render(json => {
                error    => "Cannot modify - configured via environment variable",
                from_env => 1,
            }, status => 400);
            return;
        }

        # Get current notifications config
        my $notifications = $self->settings->_config->{notifications} // {};
        $notifications->{$type} = $body;

        if ($self->settings->set_section('notifications', $notifications)) {
            # Rebuild notifiers
            $self->rebuild_notifiers->();

            $c->render(json => {
                status  => 'ok',
                message => ucfirst($type) . ' notification settings updated.',
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

sub test_notification {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $type = $c->param('type');

        unless ($type =~ /^(telegram|slack|webhook)$/) {
            $self->render_error($c, 'Invalid notification type', 400);
            return;
        }

        # Rebuild notifiers to pick up latest settings
        $self->rebuild_notifiers->();

        my $notifiers = $self->notifiers;
        unless ($notifiers->{$type}) {
            $c->render(json => {
                success => 0,
                error   => ucfirst($type) . ' is not configured',
            }, status => 400);
            return;
        }

        my $result = eval { $notifiers->{$type}->send_test() };
        if ($@ || !$result) {
            $c->render(json => {
                success => 0,
                error   => $@ // 'Test failed',
            });
        } else {
            $c->render(json => {
                success => 1,
                message => 'Test notification sent successfully',
            });
        }
    });
}

sub update_retention {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{days}) {
            $self->render_error($c, 'days required', 400);
            return;
        }

        if ($self->settings->is_from_env('retention', 'days')) {
            $c->render(json => {
                error    => 'Cannot modify - configured via PURL_RETENTION_DAYS',
                from_env => 1,
            }, status => 400);
            return;
        }

        my $days = int($body->{days});
        if ($days < 1 || $days > 365) {
            $self->render_error($c, 'days must be between 1 and 365', 400);
            return;
        }

        if ($self->settings->set('retention', 'days', $days)) {
            # Update ClickHouse TTL
            eval { $self->storage->update_retention($days) };

            $c->render(json => {
                status         => 'ok',
                retention_days => $days,
                message        => "Retention updated to $days days.",
            });
        } else {
            $self->render_error($c, 'Failed to save settings', 500);
        }
    });
}

# ============================================
# License Key Management
# ============================================

sub update_license {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && defined $body->{key}) {
            $self->render_error($c, 'License key required', 400);
            return;
        }

        if ($ENV{PURL_LICENSE_KEY}) {
            $c->render(json => {
                error    => 'Cannot modify - configured via PURL_LICENSE_KEY',
                from_env => 1,
            }, status => 400);
            return;
        }

        my $key = $body->{key};

        if ($self->settings->set('license', 'key', $key)) {
            # Reload license middleware to pick up new key
            $self->reload_license->();

            $c->render(json => {
                status  => 'ok',
                message => 'License key updated.',
            });
        } else {
            $self->render_error($c, 'Failed to save license key', 500);
        }
    });
}

# ============================================
# User Management (Pro/Enterprise)
# ============================================

sub list_users {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $auth_config = $self->settings->get_section('auth') // {};
        my $users = $auth_config->{users} // {};

        my @user_list = map { { username => $_ } } sort keys %$users;

        $c->render(json => { users => \@user_list });
    });
}

sub create_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $body = eval { decode_json($c->req->body) };
        unless ($body && $body->{username} && $body->{password}) {
            $self->render_error($c, 'Username and password required', 400);
            return;
        }

        my $username = $body->{username};
        my $password = $body->{password};

        unless ($username =~ /^[a-zA-Z0-9_-]{2,32}$/) {
            $self->render_error($c, 'Username must be 2-32 alphanumeric characters', 400);
            return;
        }

        unless (length($password) >= 6) {
            $self->render_error($c, 'Password must be at least 6 characters', 400);
            return;
        }

        my $auth_config = $self->settings->get_section('auth') // {};
        my $users = $auth_config->{users} // {};

        if (exists $users->{$username}) {
            $self->render_error($c, 'User already exists', 409);
            return;
        }

        # Check user limit from license
        my $license_info = $c->stash('license_info') // {};
        my $max_users = $license_info->{limits}{users} // 1;
        if (scalar(keys %$users) >= $max_users) {
            $self->render_error($c, "User limit reached ($max_users). Upgrade your plan.", 403);
            return;
        }

        # Hash password
        my $hashed = $self->auth_middleware->hash_password($password);
        $users->{$username} = $hashed;
        $auth_config->{users} = $users;

        if ($self->settings->set_section('auth', $auth_config)) {
            $c->render(json => { status => 'ok', username => $username });
        } else {
            $self->render_error($c, 'Failed to create user', 500);
        }
    });
}

sub update_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->param('username');
        my $body = eval { decode_json($c->req->body) };

        unless ($body && $body->{password}) {
            $self->render_error($c, 'New password required', 400);
            return;
        }

        unless (length($body->{password}) >= 6) {
            $self->render_error($c, 'Password must be at least 6 characters', 400);
            return;
        }

        my $auth_config = $self->settings->get_section('auth') // {};
        my $users = $auth_config->{users} // {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'User not found', 404);
            return;
        }

        $users->{$username} = $self->auth_middleware->hash_password($body->{password});
        $auth_config->{users} = $users;

        if ($self->settings->set_section('auth', $auth_config)) {
            $c->render(json => { status => 'ok', message => 'Password updated' });
        } else {
            $self->render_error($c, 'Failed to update user', 500);
        }
    });
}

sub delete_user {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        my $username = $c->param('username');

        my $auth_config = $self->settings->get_section('auth') // {};
        my $users = $auth_config->{users} // {};

        unless (exists $users->{$username}) {
            $self->render_error($c, 'User not found', 404);
            return;
        }

        # Prevent deleting the last user
        if (scalar(keys %$users) <= 1) {
            $self->render_error($c, 'Cannot delete the last user', 400);
            return;
        }

        # Prevent deleting yourself
        my $current = $c->stash('current_user') // '';
        if ($current eq $username) {
            $self->render_error($c, 'Cannot delete your own account', 400);
            return;
        }

        delete $users->{$username};
        $auth_config->{users} = $users;

        if ($self->settings->set_section('auth', $auth_config)) {
            $c->render(json => { status => 'ok' });
        } else {
            $self->render_error($c, 'Failed to delete user', 500);
        }
    });
}

# ============================================
# LDAP/AD Configuration (Enterprise)
# ============================================

sub get_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'ldap_auth');

        my $ldap = $self->settings->get_section('ldap') // {};

        # Never expose bind password
        my $safe = { %$ldap };
        $safe->{bind_password} = $safe->{bind_password} ? '********' : '';

        $c->render(json => {
            config   => $safe,
            from_env => {
                server        => $self->settings->is_from_env('ldap', 'server') ? 1 : 0,
                bind_dn       => $self->settings->is_from_env('ldap', 'bind_dn') ? 1 : 0,
                bind_password => $self->settings->is_from_env('ldap', 'bind_password') ? 1 : 0,
            },
        });
    });
}

sub update_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'ldap_auth');

        my $body = eval { decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Validate required fields when enabling
        if ($body->{enabled}) {
            for my $field (qw(server bind_dn search_base)) {
                unless ($body->{$field}) {
                    $self->render_error($c, "Field '$field' is required when LDAP is enabled", 400);
                    return;
                }
            }

            # Validate server URL format
            unless ($body->{server} =~ m{^ldaps?://}) {
                $self->render_error($c, "Server URL must start with ldap:// or ldaps://", 400);
                return;
            }
        }

        my $current = $self->settings->get_section('ldap') // {};

        my @updatable = qw(enabled server port bind_dn search_base search_filter
                           tls_enabled tls_verify timeout mode user_attr mail_attr
                           group_attr base_dn);

        for my $key (@updatable) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        # Only update password if explicitly provided and not masked
        if (exists $body->{bind_password} && $body->{bind_password} ne '********') {
            $current->{bind_password} = $body->{bind_password};
        }

        # Auto-set AD defaults when mode=ad
        if (($body->{mode} // '') eq 'ad') {
            $current->{user_attr}  //= 'sAMAccountName';
            $current->{group_attr} //= 'memberOf';
            $current->{mail_attr}  //= 'mail';
        }

        if ($self->settings->set_section('ldap', $current)) {
            $self->rebuild_ldap->();
            $c->render(json => { status => 'ok', message => 'LDAP settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save LDAP settings', 500);
        }
    });
}

sub test_ldap {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'ldap_auth');

        my $ldap_mw = $self->ldap_middleware;
        unless ($ldap_mw) {
            $c->render(json => {
                success => 0,
                error   => 'LDAP middleware not initialized. Save settings first.',
            });
            return;
        }

        my $available = eval { $ldap_mw->is_available() };
        if ($@ || !$available) {
            $c->render(json => {
                success => 0,
                error   => $@ ? "Connection error: $@" : 'LDAP server unreachable',
            });
            return;
        }

        $c->render(json => {
            success => 1,
            message => 'LDAP server reachable and service account bind successful.',
        });
    });
}

# ============================================
# SSO/SAML Settings (Enterprise)
# ============================================

sub get_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'sso');

        my $saml = $self->settings->get_section('saml') // {};

        # Never expose private key in plaintext
        my $safe = { %$saml };
        $safe->{sp_key} = $safe->{sp_key} ? '********' : '';

        my %from_env;
        for my $key (qw(enabled entity_id idp_entity_id idp_sso_url idp_cert acs_url sp_cert sp_key)) {
            $from_env{$key} = $self->settings->is_from_env('saml', $key) ? 1 : 0;
        }

        $c->render(json => {
            config   => $safe,
            from_env => \%from_env,
        });
    });
}

sub update_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'sso');
        return unless $self->require_role($c, 'admin');

        my $body = eval { JSON::XS::decode_json($c->req->body) };
        unless ($body) {
            $self->render_error($c, 'Invalid JSON', 400);
            return;
        }

        # Validate required fields when enabling
        if ($body->{enabled}) {
            for my $field (qw(entity_id idp_entity_id idp_sso_url idp_cert acs_url)) {
                unless ($body->{$field} && length $body->{$field}) {
                    $self->render_error($c, "Field '$field' is required when SSO is enabled", 400);
                    return;
                }
            }

            unless ($body->{acs_url} =~ m{^https?://}) {
                $self->render_error($c, 'ACS URL must start with http:// or https://', 400);
                return;
            }

            unless ($body->{idp_sso_url} =~ m{^https?://}) {
                $self->render_error($c, 'IdP SSO URL must start with http:// or https://', 400);
                return;
            }
        }

        my $current = $self->settings->get_section('saml') // {};

        my @updatable = qw(enabled entity_id idp_entity_id idp_sso_url idp_slo_url
                           idp_cert acs_url name_id_format sign_requests sp_cert
                           username_attr groups_attr allowed_groups force_authn);

        for my $key (@updatable) {
            $current->{$key} = $body->{$key} if exists $body->{$key};
        }

        # Only update sp_key if explicitly provided and not masked
        if (exists $body->{sp_key} && $body->{sp_key} ne '********') {
            $current->{sp_key} = $body->{sp_key};
        }

        if ($self->settings->set_section('saml', $current)) {
            $self->rebuild_saml->();
            $c->render(json => { status => 'ok', message => 'SSO settings updated.' });
        } else {
            $self->render_error($c, 'Failed to save SSO settings', 500);
        }
    });
}

sub test_sso {
    my ($self, $c) = @_;

    $self->safe_execute($c, sub {
        return unless $self->require_feature($c, 'sso');

        my $saml_mw = $self->saml_middleware;
        unless ($saml_mw) {
            $c->render(json => {
                success => 0,
                error   => 'SSO middleware not initialized. Save and enable settings first.',
            });
            return;
        }

        my $available = eval { $saml_mw->is_available() };
        if ($@ || !$available) {
            $c->render(json => {
                success => 0,
                error   => $@ ? "Configuration error: $@" : 'SSO is not properly configured (missing required fields)',
            });
            return;
        }

        # Test that we can build an AuthnRequest
        my $test_result = eval { $saml_mw->build_authn_request('test') };
        if ($@ || !$test_result || !$test_result->{success}) {
            $c->render(json => {
                success => 0,
                error   => $test_result->{error} // $@ // 'Failed to build test AuthnRequest',
            });
            return;
        }

        $c->render(json => {
            success => 1,
            message => 'SSO configuration is valid. SP initialized and AuthnRequest generated successfully.',
        });
    });
}

1;

__END__

=head1 NAME

Purl::API::Controller::Settings - Settings management endpoints

=head1 DESCRIPTION

Handles ClickHouse, retention, and notification settings.

=cut

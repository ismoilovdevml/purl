package Purl::API::Routes::Management;
use strict;
use warnings;
use 5.024;

# Alerts, configuration, settings, agents, backup and audit log. All
# protected. See Purl::API::Routes for %deps.
sub register {
    my (%deps) = @_;
    my $protected       = $deps{protected};
    my $ctl             = $deps{controllers};
    my $alerts          = $ctl->{alerts};
    my $alert_templates = $ctl->{alert_templates};
    my $config          = $ctl->{config};
    my $settings        = $ctl->{settings};
    my $notifications   = $ctl->{settings_notifications};
    my $api_keys        = $ctl->{settings_api_keys};
    my $users           = $ctl->{settings_users};
    my $ldap            = $ctl->{settings_ldap};
    my $sso             = $ctl->{settings_sso};
    my $ai              = $ctl->{settings_ai};
    my $redis           = $ctl->{settings_redis};
    my $agents          = $ctl->{agents};
    my $backup          = $ctl->{backup};
    my $audit           = $ctl->{audit};

    # ============================================
    # Alerts endpoints
    # ============================================
    $protected->get('/alerts' => sub { my ($c) = @_; $alerts->list($c) });
    $protected->post('/alerts' => sub { my ($c) = @_; $alerts->create($c) });
    $protected->put('/alerts/:id' => sub { my ($c) = @_; $alerts->update($c) });
    $protected->delete('/alerts/:id' => sub { my ($c) = @_; $alerts->remove($c) });
    $protected->post('/alerts/check' => sub { my ($c) = @_; $alerts->check($c) });
    $protected->post('/alerts/test-notification' => sub { my ($c) = @_; $alerts->test_notification($c) });
    $protected->get('/alerts/templates' => sub { my ($c) = @_; $alert_templates->list($c) });

    # ============================================
    # Config endpoints
    # ============================================
    $protected->get('/config' => sub { my ($c) = @_; $config->get_config($c) });
    $protected->get('/config/retention' => sub { my ($c) = @_; $config->get_retention($c) });
    $protected->put('/config/retention' => sub { my ($c) = @_; $config->update_retention($c) });
    $protected->post('/config/test-clickhouse' => sub { my ($c) = @_; $config->test_clickhouse($c) });
    $protected->get('/sources' => sub { my ($c) = @_; $config->get_sources($c) });
    $protected->delete('/cache' => sub { my ($c) = @_; $config->clear_cache($c) });

    # ============================================
    # Settings endpoints
    # ============================================
    $protected->get('/settings' => sub { my ($c) = @_; $settings->get_all($c) });
    $protected->put('/settings/clickhouse' => sub { my ($c) = @_; $settings->update_clickhouse($c) });
    $protected->put('/settings/notifications/:type' => sub { my ($c) = @_; $notifications->update_notifications($c) });
    $protected->post('/settings/notifications/:type/test' => sub { my ($c) = @_; $notifications->test_notification($c) });
    $protected->put('/settings/retention' => sub { my ($c) = @_; $settings->update_retention($c) });

    # API key rotation endpoints
    $protected->get('/settings/api-keys' => sub { my ($c) = @_; $api_keys->list_api_keys($c) });
    $protected->post('/settings/api-keys' => sub { my ($c) = @_; $api_keys->generate_api_key($c) });
    $protected->delete('/settings/api-keys/:key_id' => sub { my ($c) = @_; $api_keys->revoke_api_key($c) });

    # User management endpoints
    $protected->get('/settings/users' => sub { my ($c) = @_; $users->list_users($c) });
    $protected->post('/settings/users' => sub { my ($c) = @_; $users->create_user($c) });
    $protected->put('/settings/users/:username' => sub { my ($c) = @_; $users->update_user($c) });
    $protected->delete('/settings/users/:username' => sub { my ($c) = @_; $users->delete_user($c) });

    # LDAP/AD configuration endpoints
    $protected->get('/settings/ldap' => sub { my ($c) = @_; $ldap->get_ldap($c) });
    $protected->put('/settings/ldap' => sub { my ($c) = @_; $ldap->update_ldap($c) });
    $protected->post('/settings/ldap/test' => sub { my ($c) = @_; $ldap->test_ldap($c) });

    # SSO/SAML settings
    $protected->get('/settings/sso'       => sub { my ($c) = @_; $sso->get_sso($c) });
    $protected->put('/settings/sso'       => sub { my ($c) = @_; $sso->update_sso($c) });
    $protected->post('/settings/sso/test' => sub { my ($c) = @_; $sso->test_sso($c) });

    # AI settings
    $protected->get('/settings/ai'        => sub { my ($c) = @_; $ai->get_ai($c) });
    $protected->put('/settings/ai'        => sub { my ($c) = @_; $ai->update_ai($c) });
    $protected->post('/settings/ai/test'  => sub { my ($c) = @_; $ai->test_ai($c) });

    # Redis / Broadcast settings
    $protected->get('/settings/redis' => sub { my ($c) = @_; $redis->get_redis($c) });
    $protected->put('/settings/redis' => sub { my ($c) = @_; $redis->update_redis($c) });

    # ============================================
    # Agent management endpoints
    # ============================================
    $protected->get('/agents'              => sub { my ($c) = @_; $agents->list($c) });
    $protected->post('/agents/register'    => sub { my ($c) = @_; $agents->register($c) });
    $protected->post('/agents/heartbeat'   => sub { my ($c) = @_; $agents->heartbeat($c) });
    $protected->delete('/agents/:id'       => sub { my ($c) = @_; $agents->remove($c) });

    # ============================================
    # Backup endpoints
    # ============================================
    $protected->get('/backup/schedule' => sub { my ($c) = @_; $backup->get_schedule($c) });
    $protected->put('/backup/schedule' => sub { my ($c) = @_; $backup->update_schedule($c) });
    $protected->get('/backup/s3' => sub { my ($c) = @_; $backup->get_s3_config($c) });
    $protected->put('/backup/s3' => sub { my ($c) = @_; $backup->update_s3_config($c) });
    $protected->post('/backup/upload-s3' => sub { my ($c) = @_; $backup->upload_to_s3($c) });
    $protected->get('/backup' => sub { my ($c) = @_; $backup->list($c) });
    $protected->post('/backup' => sub { my ($c) = @_; $backup->create($c) });
    $protected->post('/backup/restore' => sub { my ($c) = @_; $backup->restore($c) });
    $protected->get('/backup/:id/download' => sub { my ($c) = @_; $backup->download($c) });
    $protected->delete('/backup/:id' => sub { my ($c) = @_; $backup->remove($c) });

    # ============================================
    # Audit log endpoints
    # ============================================
    $protected->get('/audit' => sub { my ($c) = @_; $audit->list($c) });
    $protected->get('/audit/stats' => sub { my ($c) = @_; $audit->stats($c) });

    return;
}

1;

__END__

=head1 NAME

Purl::API::Routes::Management - alert, config, settings, agent, backup and
audit routes

=cut

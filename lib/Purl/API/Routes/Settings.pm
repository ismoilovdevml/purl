package Purl::API::Routes::Settings;
use strict;
use warnings;
use 5.024;

use Exporter 'import';
use Mojo::JSON qw(decode_json);

our @EXPORT_OK = qw(setup_settings_routes);

sub setup_settings_routes {
    my ($protected, $args) = @_;

    my $settings        = $args->{settings};
    my $storage         = $args->{storage};
    my $build_storage   = $args->{build_storage};
    my $build_notifiers = $args->{build_notifiers};
    my $notifiers       = $args->{notifiers};

    $protected->get('/settings' => sub {
        my ($c) = @_;
        my $all = $settings->get_all();
        $c->render(json => {
            clickhouse => {
                host => { value => $all->{clickhouse}{host}, from_env => $settings->is_from_env('clickhouse', 'host') },
                port => { value => $all->{clickhouse}{port}, from_env => $settings->is_from_env('clickhouse', 'port') },
                database => { value => $all->{clickhouse}{database}, from_env => $settings->is_from_env('clickhouse', 'database') },
                user => { value => $all->{clickhouse}{user}, from_env => $settings->is_from_env('clickhouse', 'user') },
                password_set => { value => ($all->{clickhouse}{password} ? 1 : 0), from_env => $settings->is_from_env('clickhouse', 'password') },
            },
            retention => { days => { value => $all->{retention}{days}, from_env => $settings->is_from_env('retention', 'days') } },
            auth => { enabled => { value => $all->{auth}{enabled}, from_env => $settings->is_from_env('auth', 'enabled') } },
            notifications => {
                telegram => { enabled => $settings->get_nested('notifications', 'telegram', 'enabled') // 0,
                    bot_token => $settings->get_nested('notifications', 'telegram', 'bot_token') ? 1 : 0,
                    chat_id => $settings->get_nested('notifications', 'telegram', 'chat_id') ? 1 : 0,
                    from_env => $ENV{PURL_TELEGRAM_BOT_TOKEN} ? 1 : 0 },
                slack => { enabled => $settings->get_nested('notifications', 'slack', 'enabled') // 0,
                    webhook_set => $settings->get_nested('notifications', 'slack', 'webhook_url') ? 1 : 0,
                    channel => $settings->get_nested('notifications', 'slack', 'channel') // '',
                    from_env => $ENV{PURL_SLACK_WEBHOOK_URL} ? 1 : 0 },
                webhook => { enabled => $settings->get_nested('notifications', 'webhook', 'enabled') // 0,
                    url_set => $settings->get_nested('notifications', 'webhook', 'url') ? 1 : 0,
                    from_env => $ENV{PURL_ALERT_WEBHOOK_URL} ? 1 : 0 },
            },
        });
    });

    $protected->put('/settings/clickhouse' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'Invalid JSON' }, status => 400) unless $body;
        my @from_env = grep { $settings->is_from_env('clickhouse', $_) && exists $body->{$_} } qw(host port database user password);
        return $c->render(json => { error => "Cannot modify ENV values: " . join(', ', @from_env), from_env => \@from_env }, status => 400) if @from_env;
        my $current = $settings->get_section('clickhouse');
        $current->{$_} = $body->{$_} for grep { exists $body->{$_} } qw(host port database user password);
        if ($settings->set_section('clickhouse', $current)) {
            $build_storage->();
            $c->render(json => { status => 'ok', message => 'ClickHouse settings updated.' });
        } else {
            $c->render(json => { error => 'Failed to save settings' }, status => 500);
        }
    });

    $protected->put('/settings/notifications/:type' => sub {
        my ($c) = @_;
        my $type = $c->param('type');
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'Invalid JSON' }, status => 400) unless $body;
        return $c->render(json => { error => 'Invalid type' }, status => 400) unless $type =~ /^(telegram|slack|webhook)$/;
        my %env_check = (telegram => 'PURL_TELEGRAM_BOT_TOKEN', slack => 'PURL_SLACK_WEBHOOK_URL', webhook => 'PURL_ALERT_WEBHOOK_URL');
        return $c->render(json => { error => "Cannot modify - configured via ENV", from_env => 1 }, status => 400) if $ENV{$env_check{$type}};
        my $notifications = $settings->_config->{notifications} // {};
        $notifications->{$type} = $body;
        if ($settings->set_section('notifications', $notifications)) {
            $build_notifiers->();
            $c->render(json => { status => 'ok', message => ucfirst($type) . ' settings updated.' });
        } else {
            $c->render(json => { error => 'Failed to save' }, status => 500);
        }
    });

    $protected->post('/settings/notifications/:type/test' => sub {
        my ($c) = @_;
        my $type = $c->param('type');
        return $c->render(json => { error => 'Invalid type' }, status => 400) unless $type =~ /^(telegram|slack|webhook)$/;
        $build_notifiers->();
        return $c->render(json => { success => 0, error => ucfirst($type) . ' not configured' }, status => 400) unless $notifiers->{$type};
        my $result = eval { $notifiers->{$type}->send_test() };
        $c->render(json => $result ? { success => 1, message => 'Test sent' } : { success => 0, error => $@ // 'Failed' });
    });

    $protected->put('/settings/retention' => sub {
        my ($c) = @_;
        my $body = eval { decode_json($c->req->body) };
        return $c->render(json => { error => 'days required' }, status => 400) unless $body && $body->{days};
        return $c->render(json => { error => 'Cannot modify - from ENV', from_env => 1 }, status => 400) if $settings->is_from_env('retention', 'days');
        my $days = int($body->{days});
        return $c->render(json => { error => 'days must be 1-365' }, status => 400) if $days < 1 || $days > 365;
        if ($settings->set('retention', 'days', $days)) {
            eval { $storage->update_retention($days) };
            $c->render(json => { status => 'ok', retention_days => $days, message => "Updated to $days days." });
        } else {
            $c->render(json => { error => 'Failed to save' }, status => 500);
        }
    });
}

1;

__END__

=head1 NAME

Purl::API::Routes::Settings - Settings management routes

=cut

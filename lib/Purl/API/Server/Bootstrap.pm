package Purl::API::Server::Bootstrap;
use strict;
use warnings;
use 5.024;

use File::Basename qw(dirname);
use File::Path qw(make_path);

# One-time startup steps run by Purl::API::Server::setup_routes() in the
# prefork manager, before any worker forks: cookie sessions, the initial admin
# account, the weak-password warning and the non-fatal schema initialisation.

# Session secret for signed cookies — persist across restarts.
sub configure_sessions {
    my ($app, $settings) = @_;

    my $session_secret = $ENV{PURL_SESSION_SECRET}
        // ($settings ? $settings->get('server', 'session_secret') : undef);
    if ($session_secret && $session_secret ne '') {
        $app->log->info("Using persistent session secret");
    } else {
        $session_secret = join('', map { ('a'..'z', 'A'..'Z', 0..9)[rand 62] } 1..64);
        if ($settings) {
            $settings->set('server', 'session_secret', $session_secret);
            $app->log->info("Generated and persisted new session secret to config");
        }
        $app->log->warn("WARNING: Using ephemeral session secret — sessions won't survive restart. Set PURL_SESSION_SECRET env var for multi-replica deployments.");
    }
    $app->secrets([$session_secret]);
    $app->sessions->samesite('Strict');
    my $secure_cookies = $ENV{PURL_SECURE_COOKIES} // 0;
    $app->sessions->secure($secure_cookies);
    $app->log->info("Session cookies: secure=$secure_cookies, samesite=Strict");
    return;
}

# Generate a high-entropy admin password (never a guessable default).
sub _generate_admin_password {
    my $bytes = '';
    if (open(my $fh, '<:raw', '/dev/urandom')) {
        read($fh, $bytes, 24);
        close($fh);
    } else {
        $bytes = pack('C*', map { int(rand(256)) } 1..24);
    }
    # Alphanumeric alphabet — ~24 chars of entropy, no shell-hostile symbols.
    my @alpha = ('A'..'Z', 'a'..'z', 0..9);
    my $pw = '';
    $pw .= $alpha[ ord(substr($bytes, $_, 1)) % scalar(@alpha) ] for 0 .. length($bytes) - 1;
    return $pw;
}

# Persist the generated initial admin password to the config dir (chmod 600),
# so headless/container operators can retrieve it once. Best-effort.
sub _persist_initial_admin_password {
    my ($cfg, $password) = @_;
    return unless $cfg && $cfg->can('config_file');
    my $dir = dirname($cfg->config_file);
    eval {
        make_path($dir) unless -d $dir;
        my $path = "$dir/initial_admin_password.txt";
        open(my $fh, '>', $path) or die "open $path: $!";
        print $fh "username: admin\npassword: $password\n";
        close($fh);
        chmod 0600, $path;
        return $path;
    };
    return;
}

# Create default admin if no users exist
sub ensure_admin_user {
    my ($settings, $auth_middleware, $log) = @_;

    my $auth_section = $settings->get_section('auth') // {};
    my $users = $auth_section->{users} // {};
    return if keys %$users;

    my $admin_pass = $ENV{PURL_ADMIN_PASSWORD};
    my $generated  = 0;
    if (!defined $admin_pass || $admin_pass eq '') {
        # Never fall back to a guessable default — generate a strong one.
        $admin_pass = _generate_admin_password();
        $generated  = 1;
    }
    my $default_hash = $auth_middleware->hash_password($admin_pass);

    # Re-check under the lock. Two processes booting against the same
    # config directory must not each mint an admin and overwrite the
    # other's password — whoever gets the lock second finds a user and
    # leaves it alone.
    my $created = 0;
    $settings->update_section('auth', sub {
        my ($section) = @_;
        return if keys %{ $section->{users} // {} };
        $section->{users}   = { admin => $default_hash };
        $section->{enabled} = 1;
        $created = 1;
        return;
    });

    if (!$created) {
        $log->info('Admin user already present; leaving the existing credentials alone.');
    } elsif ($generated) {
        _persist_initial_admin_password($settings, $admin_pass);
        $log->warn('=' x 60);
        $log->warn('INITIAL ADMIN CREDENTIALS (generated once, shown only now):');
        $log->warn("    username: admin");
        $log->warn("    password: $admin_pass");
        $log->warn('Also written to <config_dir>/initial_admin_password.txt (chmod 600).');
        $log->warn('Log in and change it, then delete that file.');
        $log->warn('=' x 60);
    } else {
        $log->info("Admin user created with password from PURL_ADMIN_PASSWORD env var");
    }
    return;
}

# Warn about default/weak passwords on startup
sub warn_weak_passwords {
    my ($settings, $auth_middleware, $log) = @_;

    my $auth_enabled = $settings ? $settings->auth_enabled : 0;
    return unless $auth_enabled;

    my $auth_section = $settings->get_section('auth') // {};
    my $users = $auth_section->{users} // {};
    my @weak_passwords = qw(admin password 12345678 changeme admin123 password123 qwerty123);

    for my $username (sort keys %$users) {
        my $stored = $users->{$username};

        # Check hashed passwords against common weak passwords
        if ($stored && ($stored =~ /^\$2[aby]\$/ || $stored =~ /^[a-zA-Z0-9]+\$[a-f0-9]+$/)) {
            for my $weak (@weak_passwords) {
                my ($is_weak) = $auth_middleware->verify_password($weak, $stored);
                if ($is_weak) {
                    $log->warn("Default password detected for user '$username'. Please change it immediately.");
                    last;
                }
            }
        }
        # Check plaintext passwords (legacy format)
        elsif ($stored && grep { $stored eq $_ } @weak_passwords) {
            $log->warn("Default password detected for user '$username'. Please change it immediately.");
        }
    }
    return;
}

# Initialize the feature schemas. Each is non-fatal: a failure is logged and
# the server still starts.
sub init_schemas {
    my ($storage, $log) = @_;
    for my $schema (
        [ audit     => 'Audit' ],
        [ backup    => 'Backup' ],
        [ pipeline  => 'Pipeline' ],
        [ dashboard => 'Dashboard' ],
        [ agents    => 'Agents' ],
    ) {
        my ($name, $label) = @$schema;
        my $method = "_init_${name}_schema";
        eval { $storage->$method() };
        $log->warn("$label schema init failed: $@") if $@;
    }
    return;
}

1;

__END__

=head1 NAME

Purl::API::Server::Bootstrap - one-time pre-fork startup: session cookies,
initial admin account, weak-password warning and schema initialisation

=cut

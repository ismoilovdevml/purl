package Purl::Config;
use strict;
use warnings;
use 5.024;

use Moo;
use JSON::XS ();
use Purl::Config::Defaults;
use Purl::Config::EnvMap qw(env_var_for is_write_only is_blank);
use namespace::clean;

# Config file path
has 'config_file' => (
    is      => 'ro',
    default => sub { $ENV{PURL_CONFIG_FILE} // '/app/config/settings.json' },
);

# In-memory config cache
has '_config' => (
    is      => 'rw',
    default => sub { {} },
);

# Identity of the settings.json revision currently held in _config.
# "" means "nothing loaded yet" and always forces a load.
has '_file_stamp' => (
    is      => 'rw',
    default => sub { '' },
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->pretty->canonical },
);


# The pieces this class is built from:
#   Purl::Config::Defaults      built-in defaults (lowest precedence)
#   Purl::Config::EnvMap        section.key => ENV map, write-only keys
#   Purl::Config::Store         settings.json load/save, freshness, locking
#   Purl::Config::EnvOwnership  is_from_env / env_managed_keys / env_shadowed_keys
#   Purl::Config::Writable      what a write may put on (or erase from) disk
#   Purl::Config::UserRoles     RBAC roles
# Composed after the attributes: Store wraps the _config accessor.
with qw(
    Purl::Config::Store
    Purl::Config::EnvOwnership
    Purl::Config::Writable
    Purl::Config::UserRoles
);

# Default configuration (Purl::Config::Defaults), one shared hashref.
my $DEFAULTS = Purl::Config::Defaults::defaults();

# How long Purl::Config::Store's _acquire_lock keeps trying, and how long it
# sleeps between tries. The critical sections are a stat, a decode and a
# rename, so a contended lock clears in milliseconds; anything still blocked
# after a second is not contention, it is a wedged holder.
our $LOCK_TIMEOUT  = 1.0;
our $LOCK_RETRY_MS = 10;

sub BUILD {
    my ($self) = @_;
    $self->load();
}

# Read-modify-write a whole section atomically.
#
# $cb receives the CURRENT section (already merged with defaults, already
# reloaded under the lock) and mutates it in place. This is the only safe way
# to edit a section that other workers also edit — the get_section/mutate/
# set_section sequence spelled out by hand has a lost-update window between the
# two calls, which is how a freshly created user could vanish.
#
# $cb also receives a cancel callback: calling it aborts the write entirely and
# update_section returns false. For a read-modify-write that discovers under the
# lock that there is nothing to change (revoking a key that is not there), that
# is the difference between a no-op and rewriting the file for nothing.
sub update_section {
    my ($self, $section, $cb) = @_;

    return $self->_with_lock(sub {
        my $data = $self->get_section($section);

        my $cancelled = 0;
        $cb->($data, sub { $cancelled = 1 });
        return 0 if $cancelled;

        $self->_config->{$section} = $self->_writable_values($section, $data);
        return $self->save();
    });
}

# Get a config value with priority: ENV > file > default
sub get {
    my ($self, $section, $key) = @_;

    # 1. Check environment variable first
    my $full_key = "$section.$key";
    if (my $env = env_var_for($full_key)) {
        return $ENV{$env} if exists $ENV{$env} && defined $ENV{$env} && $ENV{$env} ne '';
    }

    # 2. Check file config
    if (exists $self->_config->{$section} && exists $self->_config->{$section}{$key}) {
        return $self->_config->{$section}{$key};
    }

    # 3. Return default
    return $DEFAULTS->{$section}{$key} // undef;
}

# Get nested config value
sub get_nested {
    my ($self, @path) = @_;

    # Build env key
    my $env_key = 'PURL_' . join('_', map { uc($_) } @path);

    # Check env first
    my %env_map = (
        'PURL_NOTIFICATIONS_TELEGRAM_BOT_TOKEN' => 'PURL_TELEGRAM_BOT_TOKEN',
        'PURL_NOTIFICATIONS_TELEGRAM_CHAT_ID'   => 'PURL_TELEGRAM_CHAT_ID',
        'PURL_NOTIFICATIONS_SLACK_WEBHOOK_URL'  => 'PURL_SLACK_WEBHOOK_URL',
        'PURL_NOTIFICATIONS_SLACK_CHANNEL'      => 'PURL_SLACK_CHANNEL',
        'PURL_NOTIFICATIONS_WEBHOOK_URL'        => 'PURL_ALERT_WEBHOOK_URL',
        'PURL_NOTIFICATIONS_WEBHOOK_AUTH_TOKEN' => 'PURL_ALERT_WEBHOOK_TOKEN',
    );

    my $mapped_key = $env_map{$env_key} // $env_key;
    return $ENV{$mapped_key} if exists $ENV{$mapped_key} && defined $ENV{$mapped_key} && $ENV{$mapped_key} ne '';

    # Check file config
    my $val = $self->_config;
    for my $key (@path) {
        return undef unless ref $val eq 'HASH' && exists $val->{$key};
        $val = $val->{$key};
    }
    return $val if defined $val;

    # Check defaults
    $val = $DEFAULTS;
    for my $key (@path) {
        return undef unless ref $val eq 'HASH' && exists $val->{$key};
        $val = $val->{$key};
    }
    return $val;
}

# Set a config value (only in file, not env)
sub set {
    my ($self, $section, $key, $value) = @_;

    # The same two values set_section refuses to write (see _writable_values),
    # refused here too. set() is the sibling that was missed: it writes straight
    # into the section, so a no-op resubmit of an ENV-owned key froze the
    # environment's value into settings.json — invisible while the variable is
    # set, a stale ghost the day it is removed. Both backup endpoints write
    # through this path.
    #
    # Reporting success is honest: the caller's guard (reject_env_managed) has
    # already refused any REAL change, so what reaches here either matches what
    # is in effect or was never filled in. Nothing to do is not a failure.
    return 1 if $self->is_from_env($section, $key);
    return 1 if is_write_only($section, $key) && is_blank($value);

    # Locked so the reload-mutate-save sequence is one step: without it a
    # concurrent worker's save between our read and our write is discarded.
    return $self->_with_lock(sub {
        $self->_config->{$section} //= {};
        $self->_config->{$section}{$key} = $value;

        return $self->save();
    });
}

# Set nested config value
sub set_nested {
    my ($self, $value, @path) = @_;

    return $self->_with_lock(sub {
        my $config = $self->_config;
        my @keys = @path;
        my $last_key = pop @keys;

        for my $key (@keys) {
            $config->{$key} //= {};
            $config = $config->{$key};
        }

        $config->{$last_key} = $value;

        return $self->save();
    });
}

# Get entire section
sub get_section {
    my ($self, $section) = @_;

    my $result = {};
    my $defaults = $DEFAULTS->{$section} // {};

    for my $key (keys %$defaults) {
        $result->{$key} = $self->get($section, $key);
    }

    # Add any extra keys from file config
    if (my $file_section = $self->_config->{$section}) {
        for my $key (keys %$file_section) {
            $result->{$key} //= $file_section->{$key};
        }
    }

    return $result;
}

# Update entire section.
#
# Wholesale replacement, so it can only ever protect OTHER sections from a
# concurrent writer. When two workers edit the SAME section — adding users is
# the case that bites — use update_section, which re-reads inside the lock.
#
# Every caller builds $data by editing a get_section() result, so it carries the
# same ENV values update_section has to strip — see _writable_values.
sub set_section {
    my ($self, $section, $data) = @_;

    return $self->_with_lock(sub {
        $self->_config->{$section} = $self->_writable_values($section, $data);
        return $self->save();
    });
}

# Get all config (merged)
sub get_all {
    my ($self) = @_;

    my $result = {};

    for my $section (keys %$DEFAULTS) {
        $result->{$section} = $self->get_section($section);
    }

    return $result;
}

# Is authentication required on this instance?
#
# ENV > file > default, resolved in ONE place. The auth gate
# (Middleware::Auth::check_auth), the startup weak-password warning and the
# `auth_required` flag /auth/me hands the login UI all read this, and they must
# never disagree — a UI that guesses instead ends up showing a login form on an
# instance that has no credentials to give.
sub auth_enabled {
    my ($self) = @_;
    return $self->get('auth', 'enabled') ? 1 : 0;
}

1;

__END__

=head1 NAME

Purl::Config - Configuration management with ENV > File > Default priority

=head1 SYNOPSIS

    use Purl::Config;

    my $config = Purl::Config->new();

    # Get value (checks ENV, then file, then default)
    my $host = $config->get('clickhouse', 'host');

    # Set value (saves to file)
    $config->set('clickhouse', 'host', 'new-host');

    # Check if from ENV (read-only)
    if ($config->is_from_env('clickhouse', 'host')) {
        # Cannot modify - set via environment
    }

=head1 CONFIGURATION PRIORITY

1. Environment Variables (highest priority, read-only)
2. Config File (/app/config/settings.json)
3. Default Values (lowest priority)

=cut

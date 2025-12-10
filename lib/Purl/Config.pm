package Purl::Config;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use YAML::XS ();
use Path::Tiny;
use Hash::Merge qw(merge);

has 'config_file' => (
    is      => 'ro',
    default => './config/default.yaml',
);

has 'config' => (
    is      => 'rw',
    lazy    => 1,
    builder => '_build_config',
);

# Default configuration
my $DEFAULTS = {
    server => {
        host    => '0.0.0.0',
        port    => 3000,
        workers => 4,
    },
    storage => {
        path           => './data/purl.db',
        retention_days => 30,
        fts_enabled    => 1,
        partition_by_day => 0,
    },
    collector => {
        batch_size     => 1000,
        flush_interval => 5,
    },
    sources => [],
    patterns => {},
    field_mappings => {
        timestamp_fields => [qw(timestamp time @timestamp date datetime)],
        level_fields     => [qw(level severity log_level loglevel priority)],
        message_fields   => [qw(message msg log text body)],
        level_mapping    => {
            emerg     => 'EMERGENCY',
            emergency => 'EMERGENCY',
            alert     => 'ALERT',
            crit      => 'CRITICAL',
            critical  => 'CRITICAL',
            err       => 'ERROR',
            error     => 'ERROR',
            warn      => 'WARNING',
            warning   => 'WARNING',
            notice    => 'NOTICE',
            info      => 'INFO',
            debug     => 'DEBUG',
            trace     => 'TRACE',
        },
    },
    dashboard => {
        default_time_range => '15m',
        max_results        => 500,
        auto_refresh       => 0,
        time_ranges        => [qw(5m 15m 30m 1h 4h 12h 24h 7d 30d)],
    },
};

sub _build_config {
    my ($self) = @_;

    my $config = { %$DEFAULTS };

    # Load from file if exists
    if (-f $self->config_file) {
        my $file_config = $self->_load_yaml($self->config_file);
        $config = merge($config, $file_config) if $file_config;
    }

    # Override from environment variables
    $config = $self->_apply_env_overrides($config);

    return $config;
}

sub _load_yaml {
    my ($self, $file) = @_;

    my $content = path($file)->slurp_utf8;
    return YAML::XS::Load($content);
}

sub _apply_env_overrides {
    my ($self, $config) = @_;

    # PURL_PORT
    if ($ENV{PURL_PORT}) {
        $config->{server}{port} = int($ENV{PURL_PORT});
    }

    # PURL_HOST
    if ($ENV{PURL_HOST}) {
        $config->{server}{host} = $ENV{PURL_HOST};
    }

    # PURL_DB_PATH
    if ($ENV{PURL_DB_PATH}) {
        $config->{storage}{path} = $ENV{PURL_DB_PATH};
    }

    # PURL_RETENTION_DAYS
    if ($ENV{PURL_RETENTION_DAYS}) {
        $config->{storage}{retention_days} = int($ENV{PURL_RETENTION_DAYS});
    }

    return $config;
}

# Reload configuration from file
sub reload {
    my ($self) = @_;
    $self->config($self->_build_config());
    return $self->config;
}

# Get a specific config value by path (e.g., 'server.port')
sub get {
    my ($self, $path) = @_;

    my @parts = split /\./, $path;
    my $value = $self->config;

    for my $part (@parts) {
        return undef unless ref $value eq 'HASH' && exists $value->{$part};
        $value = $value->{$part};
    }

    return $value;
}

# Set a config value by path
sub set {
    my ($self, $path, $value) = @_;

    my @parts = split /\./, $path;
    my $key = pop @parts;
    my $ref = $self->config;

    for my $part (@parts) {
        $ref->{$part} //= {};
        $ref = $ref->{$part};
    }

    $ref->{$key} = $value;
}

# Save configuration to file
sub save {
    my ($self, $file) = @_;

    $file //= $self->config_file;

    my $yaml = YAML::XS::Dump($self->config);
    path($file)->spew_utf8($yaml);
}

# Validate configuration
sub validate {
    my ($self) = @_;

    my @errors;

    # Check required fields
    my $port = $self->get('server.port');
    unless ($port && $port > 0 && $port < 65536) {
        push @errors, "Invalid server.port: $port";
    }

    my $db_path = $self->get('storage.path');
    unless ($db_path) {
        push @errors, "storage.path is required";
    }

    # Check sources
    for my $source (@{$self->get('sources') // []}) {
        unless ($source->{name}) {
            push @errors, "Source missing 'name' field";
        }
        if ($source->{type} eq 'file' && !$source->{path}) {
            push @errors, "File source '$source->{name}' missing 'path'";
        }
    }

    return @errors ? \@errors : undef;
}

1;

__END__

=head1 NAME

Purl::Config - Configuration management

=head1 SYNOPSIS

    use Purl::Config;

    my $config = Purl::Config->new(
        config_file => '/etc/purl/config.yaml',
    );

    my $port = $config->get('server.port');
    $config->set('server.port', 8080);

=head1 ENVIRONMENT VARIABLES

    PURL_PORT           - Override server port
    PURL_HOST           - Override server host
    PURL_DB_PATH        - Override database path
    PURL_RETENTION_DAYS - Override log retention

=cut

package Purl::API::Middleware::License;
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use HTTP::Tiny;
use Time::HiRes qw(time);
use Sys::Hostname;
use Digest::SHA qw(sha256_hex);
use POSIX qw(strftime ceil);
use File::Path qw(make_path);

has 'config' => (
    is      => 'ro',
    default => sub { {} },
);

has 'settings' => (
    is      => 'ro',
    default => sub { undef },
);

# Cached license info
has '_license_info' => (
    is      => 'rw',
    default => sub { undef },
);

has '_cache_expires' => (
    is      => 'rw',
    default => 0,
);

has '_json' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { JSON::XS->new->utf8 },
);

has '_http' => (
    is      => 'ro',
    lazy    => 1,
    default => sub { HTTP::Tiny->new(timeout => 10) },
);

# Instance ID for activation (persistent per container, stable across restarts)
has '_instance_id' => (
    is      => 'ro',
    lazy    => 1,
    default => sub {
        my $id_file = '/app/config/.instance_id';

        # Try to read existing persistent ID
        if (open my $fh, '<', $id_file) {
            my $saved_id = <$fh>;
            close $fh;
            if (defined $saved_id) {
                $saved_id =~ s/\s+$//;
                return $saved_id if length($saved_id) > 0;
            }
        }

        # Generate new unique ID: hostname + sha256 of random bytes
        my $hostname = hostname();
        my $random_hex;
        if (open my $urandom, '<:raw', '/dev/urandom') {
            my $bytes = '';
            read $urandom, $bytes, 16;
            close $urandom;
            $random_hex = sha256_hex($bytes);
        }
        else {
            $random_hex = sha256_hex("$hostname:$$:" . time() . ':' . rand());
        }

        my $new_id = substr("$hostname-$random_hex", 0, 32);

        # Persist for future restarts (ignore errors — may be read-only fs)
        if (open my $fh, '>', $id_file) {
            print $fh $new_id;
            close $fh;
        }

        return $new_id;
    },
);

# Free plan defaults (no license required)
my $FREE_PLAN = {
    plan     => 'free',
    features => ['log_search', 'live_tail', 'basic_alerts'],
    limits   => {
        servers        => 3,
        retention_days => 30,
        users          => 1,
        alerts         => 3,
    },
    activated => 0,
    valid     => 1,
};

# Trial plan (14-day Pro features)
my $TRIAL_FEATURES = ['log_search', 'live_tail', 'basic_alerts', 'pattern_analysis', 'saved_searches', 'audit_logs', 'ai_query'];
my $TRIAL_LIMITS   = { servers => 10, retention_days => 90, users => 5, alerts => 10 };
my $TRIAL_DAYS     = 14;

# ============================================
# License Verification
# ============================================

sub get_license_key {
    my ($self) = @_;
    return $ENV{PURL_LICENSE_KEY}
        // ($self->settings ? $self->settings->get('license', 'key') : '')
        // '';
}

sub get_api_url {
    my ($self) = @_;
    return $ENV{PURL_LICENSE_API_URL}
        // ($self->settings ? $self->settings->get('license', 'api_url') : '')
        // 'https://purlogs.com';
}

sub get_cache_ttl {
    my ($self) = @_;
    return $ENV{PURL_LICENSE_CACHE_TTL}
        // ($self->settings ? $self->settings->get('license', 'cache_ttl') : '')
        // 3600;
}

sub get_license_info {
    my ($self) = @_;

    # Return cached if valid
    if ($self->_license_info && time() < $self->_cache_expires) {
        return $self->_license_info;
    }

    my $license_key = $self->get_license_key();

    # No license key = check trial, then free plan
    unless ($license_key && $license_key ne '') {
        my $trial = $self->_check_trial();
        if ($trial) {
            $self->_license_info($trial);
            $self->_cache_expires(time() + 300);  # Cache for 5 min
            return $trial;
        }
        $self->_license_info($FREE_PLAN);
        $self->_cache_expires(time() + 300);  # Cache for 5 min
        return $FREE_PLAN;
    }

    # Try offline JWT verification first
    my $info = $self->_verify_jwt_offline($license_key);

    if ($info && $info->{valid}) {
        $self->_license_info($info);
        $self->_cache_expires(time() + $self->get_cache_ttl());
        return $info;
    }

    # If offline verification failed, return what we have or free plan
    my $result = $info // $FREE_PLAN;
    $self->_license_info($result);
    $self->_cache_expires(time() + 60);  # Short cache on failure
    return $result;
}

# ============================================
# Trial Management
# ============================================

sub _get_trial_file {
    my ($self) = @_;
    my $config_dir = $ENV{PURL_CONFIG_DIR} // '/app/config';
    return "$config_dir/trial.json";
}

sub _read_trial {
    my ($self) = @_;
    my $file = $self->_get_trial_file();

    return undef unless -f $file;

    my $data = eval {
        open my $fh, '<', $file or die "Cannot open $file: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        $self->_json->decode($json);
    };
    if ($@) {
        warn "Failed to read trial file $file: $@";
        return undef;
    }

    return $data;
}

sub _write_trial {
    my ($self, $data) = @_;
    my $file = $self->_get_trial_file();

    my $dir = $file;
    $dir =~ s{/[^/]+$}{};
    if ($dir && !-d $dir) {
        eval { make_path($dir) };
        if ($@) {
            warn "Failed to create trial directory $dir: $@";
            return 0;
        }
    }

    eval {
        open my $fh, '>', $file or die "Cannot write $file: $!";
        print $fh $self->_json->encode($data);
        close $fh;
    };
    if ($@) {
        warn "Failed to write trial file $file: $@";
        return 0;
    }

    return 1;
}

sub _check_trial {
    my ($self) = @_;

    my $trial = $self->_read_trial();

    # No trial file — start a new trial
    unless ($trial) {
        my $now = int(time());
        $trial = {
            started_at => $now,
            expires_at => $now + ($TRIAL_DAYS * 86400),
        };
        $self->_write_trial($trial);
    }

    my $now = time();
    my $expires_at = $trial->{expires_at} // 0;

    # Trial expired — fall through to free plan
    if ($now >= $expires_at) {
        return undef;
    }

    # Trial still active
    my $remaining_seconds = $expires_at - $now;
    my $remaining_days    = ceil($remaining_seconds / 86400);
    my $expires_at_iso    = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($expires_at));
    my $started_at_iso    = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($trial->{started_at}));

    return {
        valid               => 1,
        activated           => 0,
        plan                => 'trial',
        trial               => 1,
        trial_days_remaining => $remaining_days,
        trial_expires_at    => $expires_at_iso,
        trial_started_at    => $started_at_iso,
        features            => [@$TRIAL_FEATURES],
        limits              => {%$TRIAL_LIMITS},
    };
}

sub _verify_jwt_offline {
    my ($self, $license_key) = @_;

    eval {
        require Crypt::JWT;
    };
    if ($@) {
        warn "Crypt::JWT not available, skipping offline verification: $@";
        return { %$FREE_PLAN, error => 'Crypt::JWT not installed', valid => 0 };
    }

    # Get public key from ENV or config
    my $public_key_pem = $ENV{PURL_LICENSE_PUBLIC_KEY}
        // ($self->settings ? $self->settings->get('license', 'public_key') : '');

    # If no public key, try API activation instead
    unless ($public_key_pem && $public_key_pem ne '') {
        return undef;  # Signal to use API verification
    }

    # Fix escaped newlines in ENV vars
    $public_key_pem =~ s/\\n/\n/g;

    my $result = eval {
        my $decoded = Crypt::JWT::decode_jwt(
            token   => $license_key,
            key     => \$public_key_pem,
            alg     => 'RS256',
            verify_iss => 'purl',
            verify_exp => 1,
        );

        my $exp = $decoded->{exp} // 0;
        if ($exp < time()) {
            +{ %$FREE_PLAN, error => 'License expired', valid => 0 };
        } else {
            +{
                valid          => 1,
                activated      => 1,
                plan           => $decoded->{plan} // 'free',
                features       => $decoded->{features} // [],
                limits         => $decoded->{limits} // $FREE_PLAN->{limits},
                expires_at     => $exp,
                customer_email => $decoded->{customerEmail} // '',
                jti            => $decoded->{jti} // '',
            };
        }
    };
    if ($@) {
        my $err = "$@";
        $err =~ s/\s+$//;
        return +{ %$FREE_PLAN, error => "JWT verification failed: $err", valid => 0 };
    }

    return $result;
}

# ============================================
# API Activation (startup)
# ============================================

sub activate_with_api {
    my ($self) = @_;

    my $license_key = $self->get_license_key();
    return $FREE_PLAN unless $license_key && $license_key ne '';

    my $api_url = $self->get_api_url();
    my $url = "$api_url/api/license/activate";

    my $payload = $self->_json->encode({
        licenseKey => $license_key,
        instanceId => $self->_instance_id,
        hostname   => hostname(),
        version    => $Purl::API::Server::VERSION // '1.0.0',
    });

    my $response = $self->_http->post($url, {
        content => $payload,
        headers => {
            'Content-Type' => 'application/json',
        },
    });

    if ($response->{success}) {
        my $data = eval { $self->_json->decode($response->{content}) };
        if ($data && $data->{activated}) {
            my $info = {
                valid      => 1,
                activated  => 1,
                plan       => $data->{plan} // 'pro',
                features   => $data->{features} // [],
                limits     => $data->{limits} // {},
                expires_at => $data->{expiresAt} // '',
            };
            $self->_license_info($info);
            $self->_cache_expires(time() + $self->get_cache_ttl());
            return $info;
        }
    }

    # API activation failed - try offline
    my $offline = $self->_verify_jwt_offline($license_key);
    if ($offline && $offline->{valid}) {
        $self->_license_info($offline);
        $self->_cache_expires(time() + $self->get_cache_ttl());
        return $offline;
    }

    my $status = $response->{status} // 'unknown';
    my $error_msg = '';
    if ($response->{content}) {
        my $err = eval { $self->_json->decode($response->{content}) };
        $error_msg = $err->{error} // '' if $err;
    }

    warn "License activation failed (HTTP $status): $error_msg";
    return { %$FREE_PLAN, error => "Activation failed: $error_msg", valid => 0 };
}

# ============================================
# Heartbeat (periodic)
# ============================================

sub send_heartbeat {
    my ($self) = @_;

    my $license_key = $self->get_license_key();
    return unless $license_key && $license_key ne '';

    my $api_url = $self->get_api_url();
    my $url = "$api_url/api/license/activate";

    my $payload = $self->_json->encode({
        licenseKey => $license_key,
        instanceId => $self->_instance_id,
        hostname   => hostname(),
        version    => $Purl::API::Server::VERSION // '1.0.0',
    });

    # Non-blocking heartbeat - don't block the event loop
    eval {
        $self->_http->post($url, {
            content => $payload,
            headers => { 'Content-Type' => 'application/json' },
        });
    };
}

# ============================================
# Deactivation (shutdown)
# ============================================

sub deactivate {
    my ($self) = @_;

    my $license_key = $self->get_license_key();
    return unless $license_key && $license_key ne '';

    my $api_url = $self->get_api_url();
    my $url = "$api_url/api/license/deactivate";

    my $payload = $self->_json->encode({
        licenseKey => $license_key,
        instanceId => $self->_instance_id,
    });

    eval {
        $self->_http->post($url, {
            content => $payload,
            headers => { 'Content-Type' => 'application/json' },
        });
    };
}

# ============================================
# Feature & Limit Checks
# ============================================

sub is_feature_allowed {
    my ($self, $feature) = @_;
    my $info = $self->get_license_info();
    return 0 unless $info && $info->{valid};
    return grep { $_ eq $feature } @{ $info->{features} // [] };
}

sub check_server_limit {
    my ($self, $current_count) = @_;
    my $info = $self->get_license_info();
    return 1 unless $info && $info->{valid};
    my $max = $info->{limits}{servers} // 999;
    return 1 if $max < 0;  # -1 means unlimited
    return $current_count <= $max;
}

sub get_retention_limit {
    my ($self) = @_;
    my $info = $self->get_license_info();
    return $info->{limits}{retention_days} // 7;
}

sub get_plan {
    my ($self) = @_;
    my $info = $self->get_license_info();
    return $info->{plan} // 'free';
}

# ============================================
# Middleware Check (for protected routes)
# ============================================

sub check_license {
    my ($self, $c) = @_;

    # License check is non-blocking - always allow requests
    # but attach license info to stash for controllers to use
    my $info = $self->get_license_info();
    $info = $FREE_PLAN unless ref $info eq 'HASH';
    $c->stash('license_info' => $info);
    $c->stash('license_plan' => $info->{plan} // 'free');

    # Always return 1 - license restricts features, not access
    return 1;
}

1;

__END__

=head1 NAME

Purl::API::Middleware::License - License verification and feature gating

=head1 SYNOPSIS

    use Purl::API::Middleware::License;

    my $license = Purl::API::Middleware::License->new(
        config   => $config,
        settings => $settings,
    );

    # Activate on startup
    my $info = $license->activate_with_api();

    # Check features
    if ($license->is_feature_allowed('pattern_analysis')) {
        # Pro/Enterprise feature
    }

    # Get plan info
    my $plan = $license->get_plan();  # 'free', 'pro', 'enterprise'

=head1 DESCRIPTION

Manages license key verification for Purl self-hosted instances.

License keys are JWT tokens (RS256) generated by purlogs.com and contain:
plan type, feature list, server/retention limits, and expiry.

Verification priority:
1. Offline JWT verification (using RSA public key)
2. Online API activation (purlogs.com/api/license/activate)
3. Fallback to free plan (graceful degradation)

=head1 ENVIRONMENT VARIABLES

    PURL_LICENSE_KEY        - JWT license key (from purlogs.com dashboard)
    PURL_LICENSE_PUBLIC_KEY - RSA public key for offline verification
    PURL_LICENSE_API_URL    - API URL (default: https://purlogs.com)
    PURL_LICENSE_CACHE_TTL  - Cache TTL in seconds (default: 3600)

=cut

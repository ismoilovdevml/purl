package Purl::License::Plans;
use strict;
use warnings;
use 5.024;

# ============================================================================
# Purl::License::Plans
#
# THE single source of truth for what each plan grants. Mirrors purl-web's
# `src/lib/stripe/config.ts` EXACTLY — that file is what the pricing pages,
# Stripe products and the license-key issuer read; this file is what the
# self-hosted backend enforces. If the two disagree, a paying customer either
# gets a 403 for something they bought or gets something they did not.
#
# RULES
#   * Tiers are cumulative: pro > free, enterprise > pro.
#   * Feature IDs here MUST match the `require_feature($c, '<id>')` gate names
#     used in lib/Purl/API/Controller/*.pm. A name nobody gates sells nothing.
#   * Trial == Pro, from this file. Never hand-maintain a second trial list:
#     a trial feature missing from Pro means the feature DISAPPEARS the moment
#     the customer pays, which is exactly how you manufacture churn.
# ============================================================================

# --- Feature IDs ------------------------------------------------------------

my @FREE_FEATURES = qw(
    log_search
    live_tail
    basic_alerts
    pattern_analysis
    saved_searches_unlimited
    telegram_alerts
    slack_alerts
    self_hosted
);

my @PRO_FEATURES = (@FREE_FEATURES, qw(
    dashboards
    webhook_alerts
    ai_query
    ai_analysis
    pipelines
    backup
    es_compat
    k8s_monitoring
    priority_support
));

my @ENTERPRISE_FEATURES = (@PRO_FEATURES, qw(
    sso
    ldap_auth
    audit_logs
    dedicated_support
));

my %PLAN_FEATURES = (
    free       => \@FREE_FEATURES,
    pro        => \@PRO_FEATURES,
    enterprise => \@ENTERPRISE_FEATURES,
    # Trial is Pro — same list, same object of truth.
    trial      => \@PRO_FEATURES,
);

# --- Limits -----------------------------------------------------------------
#
# Purl is self-hosted: servers, agents, users, alert rules and saved searches
# all run on the customer's own hardware, so no plan meters them. -1 means
# unlimited and is what Controller::Base::check_limit short-circuits on.
#
# `retention_days` is deliberately ABSENT. Nothing in the backend reads it —
# retention is driven solely by PURL_RETENTION_DAYS on the customer's own
# ClickHouse. Shipping a number we cannot enforce is a false promise.

my @LIMIT_NAMES = qw(servers agents users alerts saved_searches);

# --- API --------------------------------------------------------------------

# Feature list for a plan, as a fresh arrayref (callers must not be able to
# mutate the catalogue).
sub features_for {
    my ($plan) = @_;
    $plan //= 'free';
    my $list = $PLAN_FEATURES{$plan} // $PLAN_FEATURES{free};
    return [@$list];
}

# Every metered limit set to unlimited (-1). Fresh hashref per call.
sub unlimited_limits {
    return { map { $_ => -1 } @LIMIT_NAMES };
}

# The license-info structure used when no license key and no active trial
# exist. Fresh structure per call so no caller can corrupt the default.
sub free_plan {
    return {
        plan      => 'free',
        features  => features_for('free'),
        limits    => unlimited_limits(),
        activated => 0,
        valid     => 1,
    };
}

sub limit_names { return [@LIMIT_NAMES] }

sub plan_names { return [qw(free pro enterprise)] }

1;

__END__

=head1 NAME

Purl::License::Plans - Canonical plan -> features/limits catalogue

=head1 SYNOPSIS

    use Purl::License::Plans;

    my $features = Purl::License::Plans::features_for('pro');
    my $limits   = Purl::License::Plans::unlimited_limits();
    my $free     = Purl::License::Plans::free_plan();

=head1 DESCRIPTION

Single source of truth for plan entitlements in the self-hosted backend.
Kept byte-for-byte in sync with purl-web's C<src/lib/stripe/config.ts>.

Free grants every self-hosted capability with unlimited quotas; Pro adds
dashboards, AI, pipelines, backup, ES-compat and K8s monitoring; Enterprise
adds SSO, LDAP and audit logs. The 14-day trial is Pro, derived from the same
list so a paid upgrade can never take a feature away.

=cut

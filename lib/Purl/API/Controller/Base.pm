package Purl::API::Controller::Base;
use strict;
use warnings;
use 5.024;

use Moo;

# Imported BEFORE namespace::clean — anything imported after it is not cleaned,
# and plan_search_query would leak into every controller subclass as a method.
use Purl::Util::SearchQuery qw(plan_search_query);

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

sub invalidate_cached {
    my ($self, $key) = @_;
    return delete $self->cache->{$key};
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
# Search query handling
# ============================================

# Translate a user query string into storage filter params.
#
# Plain text stays plain text (see Purl::Util::SearchQuery): the search box is
# mostly used to paste log fragments, and running those through the KQL grammar
# made `at Foo::bar()` a 400. Only a string carrying an explicit KQL marker is
# parsed, and then a syntax error IS an error — silently dropping an
# unparsable filter is how `level:error AND service:x` came to return more rows
# than `level:error`.
#
# Returns 1 on success, having merged the resulting params into $params.
# On failure it renders 400 and returns 0 — the caller MUST stop.
#
# Lives here, not in Controller::Logs, because SavedSearches validates a query
# at save time with exactly this rule and two copies would drift apart.
sub _apply_query {
    my ($self, $c, $params, $query) = @_;

    my ($fragment, $err) = plan_search_query($query);
    if ($err) {
        $self->render_error($c, "Invalid query syntax: $err", 400);
        return 0;
    }

    @{$params}{ keys %$fragment } = values %$fragment;
    return 1;
}

# ============================================
# License enforcement helpers
# ============================================

# Feature-name alias map. The license (issued by purl-web) sometimes grants
# a feature under a DIFFERENT name than the internal gate uses. Rather than
# rename the many require_feature() call sites, a gate's canonical internal
# name is satisfied by the canonical name OR any of its known aliases present
# in the license. Canonical gate name => arrayref of accepted alias names.
#
# NOTE: aliasing only bridges pure NAME mismatches where the license DOES
# grant an equivalent feature under another name. It CANNOT grant a feature
# the license omits entirely — those require purl-web to add the feature to
# the plan's feature list and re-issue keys.
my %FEATURE_ALIASES = (
    # purl-web issues Dashboards as 'custom_dashboards'; internal gate is
    # 'dashboards'. Same capability, different name.
    dashboards => [qw( custom_dashboards )],
);

# Non-rendering feature check. Returns 1 if the current license grants
# $feature — OR if no license context is present at all (matching the
# historical require_feature behaviour of allowing when unlicensed/OSS).
# Returns 0 otherwise. NEVER renders. Shared by require_feature (renders a
# 403 on failure) and the ingest pipeline path (stays silent on failure).
sub has_feature {
    my ($self, $c, $feature) = @_;
    my $info = $c->stash('license_info') // return 1;
    my $plan = $info->{plan} // 'free';

    # Enterprise plan has access to all features
    return 1 if $plan eq 'enterprise';

    # A gate is satisfied by its canonical name OR any known alias the
    # license grants instead (name-mismatch bridge — see %FEATURE_ALIASES).
    my %granted = map { $_ => 1 } @{ $info->{features} // [] };
    return 1 if $granted{$feature};
    for my $alias (@{ $FEATURE_ALIASES{$feature} // [] }) {
        return 1 if $granted{$alias};
    }
    return 0;
}

sub require_feature {
    my ($self, $c, $feature) = @_;
    return 1 if $self->has_feature($c, $feature);

    # Only reached when a license context exists but lacks the feature.
    my $info = $c->stash('license_info') // {};
    my $plan = $info->{plan} // 'free';
    $c->render(json => {
        error   => "This feature requires a Pro or Enterprise license",
        feature => $feature,
        plan    => $plan,
        upgrade => 'https://purlogs.com/pricing',
    }, status => 403);
    return 0;
}

# THE quota gate. Every limit check in the codebase goes through here — there
# is no second implementation, because the one rule everybody forgets is that
# a limit of -1 means UNLIMITED, and an open-coded `$count >= $max` turns
# "unlimited" into "nothing allowed at all" (0 >= -1 is true).
#
#   $current_count : how many of the thing already exist
#   $adding        : how many the caller wants to add (default 1)
#
# Renders a 403 and returns 0 when the request would exceed the quota;
# returns 1 (and renders nothing) otherwise, including when no license context
# is attached or the plan does not meter this resource at all.
sub check_limit {
    my ($self, $c, $limit_name, $current_count, $adding) = @_;
    $adding //= 1;
    my $info = $c->stash('license_info') // return 1;
    my $max = $info->{limits}{$limit_name} // return 1;
    return 1 if $max < 0;  # -1 means unlimited
    return 1 if $current_count + $adding <= $max;
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

# ============================================
# Ingest-path pipeline processing
#
# Shared by all three ingest controllers (Logs, OTLP, Syslog) so the
# "cheaply build the pipeline engine + run each log through it" logic
# lives in exactly ONE place. Lives on Base (rather than a free module)
# because it needs storage, config, and the get_cached/set_cached cache
# — all already on Base — plus $c for the license context; a standalone
# module would only re-plumb those same four things.
# ============================================

# Build (and briefly cache) the pipeline engine for the ingest hot path.
# Returns the engine, or undef when pipelines should be skipped entirely
# (feature not licensed, storage without pipeline support, or a load
# error). NEVER dies and NEVER renders — ingest must not break because
# pipelines are unavailable.

# Cache key + TTL for the built ingest pipeline engine. Named here (not
# inlined) so pipeline_engine() and invalidate_pipeline_engine() can never
# disagree about which entry to write and drop.
our $PIPELINE_ENGINE_CACHE_KEY = 'ingest:pipeline_engine';

# TTL deliberately SHORT (was 60s). The cache exists only to keep ingest off
# a per-request list_pipelines() round-trip, and a few seconds of hits already
# achieves that under any real ingest rate. The TTL doubles as the correctness
# bound for CRUD changes: invalidate_pipeline_engine() drops the entry in the
# worker that served the edit, but under prefork EVERY worker holds its own
# copy of this cache (%cache is created per-process in Server.pm) and there is
# no cross-worker invalidation channel. So the worst case for a pipeline edit
# to take effect everywhere is this TTL, not 60s.
our $PIPELINE_ENGINE_CACHE_TTL = 5;

sub pipeline_engine {
    my ($self, $c) = @_;

    # Licensed feature — on the ingest path, skip SILENTLY if not granted
    # (has_feature does not render, unlike require_feature).
    return undef unless $self->has_feature($c, 'pipelines');

    # Storage backend may not support pipelines (alt backends / tests).
    return undef unless $self->storage->can('list_pipelines');

    # Avoid a DB round-trip per ingest request: cache the built engine
    # briefly (same get_cached/set_cached pattern as the ingest
    # known-services cache in Logs::ingest).
    if (my $cached = $self->get_cached($PIPELINE_ENGINE_CACHE_KEY)) {
        return $cached;
    }

    require Purl::Pipeline::Engine;

    my $pipelines = eval { $self->storage->list_pipelines() } // [];

    # ReDoS guard bounds come from the config contract (pipeline.*),
    # mirroring the engine build in Controller::Pipeline. This is why the
    # regex-safety limits had to land before wiring the ingest path.
    my $pcfg = (ref $self->config eq 'HASH')
        ? ($self->config->{pipeline} // {})
        : {};

    my $engine = Purl::Pipeline::Engine->new(
        regex_timeout_ms => $pcfg->{regex_timeout_ms} // 250,
        regex_max_length => $pcfg->{regex_max_length} // 512,
        pipelines        => $self->_enabled_pipelines($pipelines),
    );

    return $self->set_cached($PIPELINE_ENGINE_CACHE_KEY, $engine, $PIPELINE_ENGINE_CACHE_TTL);
}

# Drop the cached ingest engine so the next ingest rebuilds it from storage.
# MUST be called after every pipeline create/update/delete — otherwise the
# edit is invisible to ingest until the TTL lapses. %cache is the single
# hashref shared by all controllers in this process (Server.pm passes the same
# \%cache to each), so invalidating from Controller::Pipeline is immediately
# visible to Controller::Logs. Cross-worker propagation is TTL-bounded — see
# $PIPELINE_ENGINE_CACHE_TTL.
sub invalidate_pipeline_engine {
    my ($self) = @_;
    return $self->invalidate_cached($PIPELINE_ENGINE_CACHE_KEY);
}

# Keep only enabled pipelines and normalise JSON-boolean enabled flags.
# list_pipelines emits enabled as \1/\0 (JSON bool refs) so the API can
# serialise them — but EVERY ref is truthy to the engine's
# `next unless $pipeline->{enabled}` check, so a disabled (\0) pipeline
# would run on ingest. Dereference to a plain 0/1 and drop the disabled
# ones here. Rule-level enabled flags are normalised defensively too.
sub _enabled_pipelines {
    my ($self, $pipelines) = @_;
    return [] unless ref $pipelines eq 'ARRAY';

    my @out;
    for my $p (@$pipelines) {
        next unless ref $p eq 'HASH';
        my $enabled = $p->{enabled};
        $enabled = ${$enabled} if ref $enabled;   # deref JSON bool
        next unless $enabled;

        for my $rule (@{ $p->{rules} // [] }) {
            next unless ref $rule eq 'HASH';
            $rule->{enabled} = ${ $rule->{enabled} } if ref $rule->{enabled};
        }
        push @out, $p;
    }
    return \@out;
}

# Run a batch of logs through the configured pipelines before storage.
# Returns the arrayref of logs to insert:
#   * enriched / rewritten logs replace their originals,
#   * logs matched by a drop rule are removed (not returned),
#   * a pipeline/rule that THROWS is caught and the ORIGINAL log is kept
#     (fail-safe — a broken rule must never lose logs or 500 the ingest).
# When pipelines are unavailable the input arrayref is returned unchanged.
sub apply_pipelines {
    my ($self, $c, $logs) = @_;
    return $logs unless ref $logs eq 'ARRAY' && @$logs;

    my $engine = $self->pipeline_engine($c);
    return $logs unless $engine;
    return $logs unless @{ $engine->pipelines };   # nothing configured

    my @out;
    for my $log (@$logs) {
        my $processed = eval { $engine->process($log) };
        if ($@) {
            $c->app->log->error("Pipeline processing error: $@");
            push @out, $log;             # fail-safe: keep the original
            next;
        }
        next unless defined $processed;  # drop rule matched — skip insert
        push @out, $processed;
    }
    return \@out;
}

1;

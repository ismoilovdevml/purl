#!/usr/bin/env perl
use strict;
use warnings;
use 5.024;

# ============================================================================
# License plan matrix — end-to-end, over real HTTP, with real license keys.
#
# WHY THIS EXISTS
#   Feature gating is revenue-critical and silently breakable: a feature ID
#   renamed on either side of the wire (purl-web's stripe/config.ts issues the
#   names, lib/Purl/API/Controller/*.pm gates on them) turns into a 403 for a
#   customer who paid for exactly that feature. That has already happened once:
#   Pro customers got 403 on six features because the issued license did not
#   carry the names the gates check.
#
#   Nothing here is mocked on the license path. The test generates a throwaway
#   RSA keypair at runtime, signs real RS256 license JWTs with the SAME claim
#   shape purl-web's src/lib/license/generate.ts emits, hands the public key to
#   the server via PURL_LICENSE_PUBLIC_KEY, and drives the real
#   Purl::API::Server over Test::Mojo. Only ClickHouse is replaced (in-memory).
#
#   KEYS: the keypair is generated in-process, lives only in memory, and is
#   never written to disk. The production signing key
#   (purl-web/keys/private.pem) is NEVER read, copied or referenced.
#
# HOW TO EXTEND
#   Add ONE row to @MATRIX. Do not add a test function. Each row states, per
#   plan, the exact HTTP status the endpoint must answer with. The expectations
#   are hand-written on purpose — deriving them from Purl::License::Plans would
#   make the test agree with any mutation of the catalogue and assert nothing.
# ============================================================================

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use File::Temp qw(tempdir);
use File::Spec;
use Mojo::JSON qw(encode_json);

BEGIN {
    eval { require Crypt::JWT; require Crypt::PK::RSA; 1 }
        or plan skip_all => 'Crypt::JWT / Crypt::PK::RSA (CryptX) not installed';
}

# ---------------------------------------------------------------------------
# 0. Throwaway signing keypair (in memory only)
# ---------------------------------------------------------------------------
my $rsa = Crypt::PK::RSA->new;
$rsa->generate_key(256, 65537);            # 2048-bit, test-only, never persisted
my $PRIVATE_PEM = $rsa->export_key_pem('private');
my $PUBLIC_PEM  = $rsa->export_key_pem('public');

# ---------------------------------------------------------------------------
# 1. Environment — must be set BEFORE the app is built
# ---------------------------------------------------------------------------
my $CONFIG_DIR  = tempdir(CLEANUP => 1);
my $CONFIG_FILE = File::Spec->catfile($CONFIG_DIR, 'settings.json');
my $TRIAL_FILE  = File::Spec->catfile($CONFIG_DIR, 'trial.json');
my $TRIAL_DONE  = "$TRIAL_FILE.expired";

$ENV{PURL_CONFIG_DIR}         = $CONFIG_DIR;
$ENV{PURL_CONFIG_FILE}        = $CONFIG_FILE;
$ENV{PURL_AUTH_ENABLED}       = '1';       # need a session so role=admin is real
$ENV{PURL_LDAP_ENABLED}       = '0';
$ENV{PURL_SAML_ENABLED}       = '0';
$ENV{PURL_SESSION_SECRET}     = 'license-matrix-secret-key-1234567890abcdef';
$ENV{PURL_LICENSE_PUBLIC_KEY} = $PUBLIC_PEM;
# Unreachable on purpose: nothing in this test may touch purlogs.com.
$ENV{PURL_LICENSE_API_URL}    = 'http://127.0.0.1:1';
$ENV{PURL_CLICKHOUSE_HOST}    = '127.0.0.1';
$ENV{PURL_CLICKHOUSE_PORT}    = '19999';
delete $ENV{PURL_LICENSE_KEY};
delete $ENV{PURL_API_KEYS};

# Seed an admin whose password hash is produced by the real hasher.
require Purl::API::Middleware::Auth;
my $ADMIN_PASS = 'matrix-admin-pass-1';
my $ADMIN_HASH = Purl::API::Middleware::Auth->new(config => {})->hash_password($ADMIN_PASS);
{
    open my $fh, '>', $CONFIG_FILE or die "seed settings.json: $!";
    print {$fh} encode_json({
        auth => {
            enabled => 1,
            users   => { admin => { password => $ADMIN_HASH, role => 'admin' } },
        },
    });
    close $fh;
}

# ---------------------------------------------------------------------------
# 2. In-memory storage — ClickHouse is the ONLY thing stubbed here
#
# Declared as a stub table rather than 30 hand-written subs, but installed as
# real named subs so ->can() (which Controller::Base::pipeline_engine relies on)
# keeps working.
# ---------------------------------------------------------------------------
{
    package Purl::Storage::MatrixMock;
    use Moo;

    has '_alerts'  => (is => 'rw', default => sub { [] });
    has '_saved'   => (is => 'rw', default => sub { [] });
    has '_agents'  => (is => 'rw', default => sub { [] });
    has '_users_created' => (is => 'rw', default => 0);

    my %STUBS = (
        # schema init (called at server boot, eval-wrapped)
        _init_audit_schema     => sub { 1 },
        _init_dashboard_schema => sub { 1 },
        _init_agents_schema    => sub { 1 },
        _init_backup_schema    => sub { 1 },
        _init_pipeline_schema  => sub { 1 },
        # health / metrics
        stats       => sub { { total_logs => 0, db_size_bytes => 0, db_size_mb => 0 } },
        get_metrics => sub {
            {   queries_total => 0, queries_cached => 0, inserts_total => 0,
                bytes_inserted => 0, buffer_size => 0, errors_total => 0 }
        },
        flush       => sub { 1 },
        maybe_flush => sub { 1 },
        # search (ES-compat)
        search => sub { [] },
        count  => sub { 0 },
        # patterns
        get_patterns      => sub { [] },
        get_pattern_logs  => sub { [] },
        get_pattern_stats => sub { { total_patterns => 0, top_patterns => [] } },
        # dashboards
        list_dashboards => sub { [] },
        # pipelines
        list_pipelines => sub { [] },
        # backup
        list_backups => sub { [] },
        # k8s health
        get_k8s_pod_count      => sub { 0 },
        get_pod_health_summary => sub { [] },
        get_unhealthy_pods     => sub { [] },
        # audit
        get_audit_logs   => sub { [] },
        count_audit_logs => sub { 0 },
        log_audit_event  => sub { 1 },
        get_audit_stats  => sub { { total => 0 } },
    );

    for my $name (keys %STUBS) {
        no strict 'refs';    ## no critic (ProhibitNoStrict)
        *{ __PACKAGE__ . "::$name" } = $STUBS{$name};
    }

    # Stateful bits the quota assertions need to observe.
    sub get_alerts   { $_[0]->_alerts }
    sub create_alert { my ($s, %a) = @_; push @{ $s->_alerts }, { %a, enabled => 1 }; 1 }

    sub get_saved_searches { $_[0]->_saved }

    sub create_saved_search {
        my ($s, $name, $query, $range) = @_;
        push @{ $s->_saved }, { id => 'ss-' . scalar @{ $s->_saved },
                                name => $name, query => $query,
                                time_range => $range // '15m' };
        return 1;
    }

    sub get_agents    { $_[0]->_agents }
    sub count_agents  { scalar @{ $_[0]->_agents } }
    sub register_agent { my ($s, $a) = @_; push @{ $s->_agents }, $a; 1 }
}

# ---------------------------------------------------------------------------
# 3. Build the real app, keeping a handle on the real license middleware
# ---------------------------------------------------------------------------
require Purl::API::Server;
require Purl::API::Middleware::License;

my $license_mw;
{
    no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)
    my $orig_new = Purl::API::Middleware::License->can('new');
    *Purl::API::Middleware::License::new = sub {
        my $obj = $orig_new->(@_);
        $license_mw = $obj;
        return $obj;
    };
}

my $storage = Purl::Storage::MatrixMock->new;
{
    no warnings qw(redefine once);    ## no critic (ProhibitNoWarnings)
    *Purl::API::Server::_build_storage = sub { return $storage };
}

my $server = Purl::API::Server->create(config => {
    auth       => { enabled => 1 },
    rate_limit => { max_requests => 100_000 },
});
my $app = $server->setup_routes();

ok $license_mw, 'captured the live license middleware instance';

use Test::Mojo;
my $t = Test::Mojo->new($app);

# ---------------------------------------------------------------------------
# 4. Real license keys — same claims purl-web's generate.ts signs
# ---------------------------------------------------------------------------

# Hand-written mirror of purl-web src/lib/stripe/config.ts. This is the
# CONTRACT, not a copy of Purl::License::Plans — the whole point is that the
# two are compared, so neither may be derived from the other.
my %WEB_FEATURE_IDS;
$WEB_FEATURE_IDS{free} = [qw(
    log_search live_tail basic_alerts pattern_analysis
    saved_searches_unlimited telegram_alerts slack_alerts self_hosted
)];
$WEB_FEATURE_IDS{pro} = [ @{ $WEB_FEATURE_IDS{free} }, qw(
    dashboards webhook_alerts ai_query ai_analysis pipelines
    backup es_compat k8s_monitoring priority_support
) ];
$WEB_FEATURE_IDS{enterprise} = [ @{ $WEB_FEATURE_IDS{pro} }, qw(
    sso ldap_auth audit_logs dedicated_support
) ];

sub issue_license_key {
    my ($plan, %opt) = @_;
    my $now = time();
    return Crypt::JWT::encode_jwt(
        payload => {
            iss    => 'purl',
            sub    => 'user_matrix_test',
            aud    => 'self-hosted',
            iat    => $now,
            exp    => $now + ($opt{expires_in} // 30 * 86400),
            jti    => sprintf('%032x', $now),
            plan   => $plan,
            # purl-web emits exactly these four limit keys, all -1.
            limits => { servers => -1, agents => -1, users => -1, alerts => -1 },
            features       => [ @{ $WEB_FEATURE_IDS{$plan} } ],
            customerEmail  => 'matrix@example.com',
        },
        key => \$PRIVATE_PEM,
        alg => 'RS256',
    );
}

my %LICENSE_KEY = map { $_ => issue_license_key($_) } qw(pro enterprise);

# Switch the running server onto a plan. Everything downstream of this — trial
# discovery, RS256 verification, feature extraction — is the production path.
sub activate_plan {
    my ($plan) = @_;

    if ($plan eq 'free') {
        delete $ENV{PURL_LICENSE_KEY};
        my $expired = time() - 86400;
        _write_json($TRIAL_FILE, { started_at => $expired - 14 * 86400,
                                   expires_at => $expired });
        open my $fh, '>', $TRIAL_DONE or die $!;
        print {$fh} 'expired';
        close $fh;
    }
    elsif ($plan eq 'trial') {
        delete $ENV{PURL_LICENSE_KEY};
        unlink $TRIAL_DONE;
        my $now = time();
        _write_json($TRIAL_FILE, { started_at => $now,
                                   expires_at => $now + 14 * 86400 });
    }
    else {
        $ENV{PURL_LICENSE_KEY} = $LICENSE_KEY{$plan}
            or die "no license key for plan '$plan'";
    }

    # Drop the middleware's TTL cache so the next request re-resolves the plan.
    $license_mw->_license_info(undef);
    $license_mw->_cache_expires(0);
    return;
}

sub _write_json {
    my ($path, $data) = @_;
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} encode_json($data);
    close $fh;
    return;
}

# ---------------------------------------------------------------------------
# 5. Log in once as admin (session cookie + CSRF token for mutating requests)
# ---------------------------------------------------------------------------
activate_plan('free');

$t->post_ok('/api/auth/login', json => { username => 'admin', password => $ADMIN_PASS })
  ->status_is(200)
  ->json_is('/authenticated' => 1)
  ->json_is('/role'          => 'admin');

$t->get_ok('/api/csrf-token')->status_is(200);
my $CSRF = $t->tx->res->json->{csrf_token};
ok $CSRF, 'obtained a CSRF token for mutating requests';

my %HDR = ('X-CSRF-Token' => $CSRF, 'Content-Type' => 'application/json');

# ---------------------------------------------------------------------------
# 6. THE MATRIX
#
# One row per gated capability. `expect` is plan => required HTTP status.
#   403 => the gate must reject and name the feature in the body
#   any other code => the gate must let the request through (the code is what
#                     the handler answers with once past the gate)
#
# 400 on the AI rows is "gate passed, no AI provider configured in this test
# instance" — deliberately recorded so a regression that turns it into 403
# (feature lost) or 200 (gate removed) both fail.
# ---------------------------------------------------------------------------
my @MATRIX = (
    # ---- Free tier capabilities: must work on EVERY plan ----
    {   gate   => 'pattern_analysis', method => 'GET', path => '/api/patterns',
        expect => { free => 200, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'telegram_alerts', method => 'POST', path => '/api/alerts',
        body   => { name => 'tg', notify_type => 'telegram' },
        expect => { free => 200, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'slack_alerts', method => 'POST', path => '/api/alerts',
        body   => { name => 'sl', notify_type => 'slack' },
        expect => { free => 200, trial => 200, pro => 200, enterprise => 200 },
    },
    # Saved searches carry NO feature gate (quota only) — must never 403.
    {   gate   => '(ungated) saved searches read', method => 'GET',
        path   => '/api/saved-searches',
        expect => { free => 200, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => '(ungated) saved searches write', method => 'POST',
        path   => '/api/saved-searches',
        body   => { name => 'errors', query => 'level:ERROR' },
        expect => { free => 200, trial => 200, pro => 200, enterprise => 200 },
    },

    # ---- Pro tier: denied on Free, granted on Trial/Pro/Enterprise ----
    {   gate   => 'dashboards', method => 'GET', path => '/api/dashboards',
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'webhook_alerts', method => 'POST', path => '/api/alerts',
        body   => { name => 'wh', notify_type => 'webhook' },
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'ai_query', method => 'POST', path => '/api/ai/query',
        body   => { question => 'show me errors from the last hour' },
        expect => { free => 403, trial => 400, pro => 400, enterprise => 400 },
    },
    {   gate   => 'ai_analysis', method => 'POST', path => '/api/ai/analyze',
        body   => { range => '1h' },
        expect => { free => 403, trial => 400, pro => 400, enterprise => 400 },
    },
    {   gate   => 'pipelines', method => 'GET', path => '/api/pipelines',
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'backup', method => 'GET', path => '/api/backup',
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'es_compat', method => 'POST', path => '/api/es/_search',
        body   => { size => 1, query => { match_all => {} } },
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },
    {   gate   => 'k8s_monitoring', method => 'GET', path => '/api/k8s/health',
        expect => { free => 403, trial => 200, pro => 200, enterprise => 200 },
    },

    # ---- Enterprise tier: denied on Free/Trial/Pro ----
    {   gate   => 'audit_logs', method => 'GET', path => '/api/audit',
        expect => { free => 403, trial => 403, pro => 403, enterprise => 200 },
    },
    {   gate   => 'sso', method => 'GET', path => '/api/settings/sso',
        expect => { free => 403, trial => 403, pro => 403, enterprise => 200 },
    },
    {   gate   => 'ldap_auth', method => 'GET', path => '/api/settings/ldap',
        expect => { free => 403, trial => 403, pro => 403, enterprise => 200 },
    },
);

my @PLANS = qw(free trial pro enterprise);

sub call_row {
    my ($row) = @_;
    my $method = lc $row->{method};
    if ($method eq 'get') {
        $t->get_ok($row->{path}, \%HDR);
    }
    else {
        $t->post_ok($row->{path}, \%HDR, json => $row->{body} // {});
    }
    return $t->tx->res;
}

for my $plan (@PLANS) {
    subtest "plan=$plan feature matrix" => sub {
        activate_plan($plan);

        # The plan the server itself reports must be the one we asked for.
        $t->get_ok('/api/license')->status_is(200)->json_is('/plan' => $plan);

        for my $row (@MATRIX) {
            my $want = $row->{expect}{$plan};
            my $res  = call_row($row);
            my $label = "$row->{method} $row->{path} [$row->{gate}]";

            is $res->code, $want, "$label => $want";

            if ($want == 403) {
                is $res->json->{feature}, $row->{gate},
                    "$label 403 names the gate (dashboard renders the upsell from it)";
                like $res->json->{upgrade} // '', qr{purlogs\.com/pricing},
                    "$label 403 carries the upgrade link";
            }
            else {
                isnt $res->code, 403, "$label is not feature-blocked on $plan";
            }
        }
    };
}

# ---------------------------------------------------------------------------
# 7. Catalogue conformance — the backend's plan table vs. purl-web's
#
# The matrix above proves the gates behave; this proves the names on the wire
# still match what the license issuer emits. A rename that keeps behaviour
# consistent on both sides of Plans.pm would slip past the matrix alone.
# ---------------------------------------------------------------------------
require Purl::License::Plans;

subtest 'Plans.pm matches purl-web stripe/config.ts feature IDs' => sub {
    for my $plan (qw(free pro enterprise)) {
        is_deeply
            [ sort @{ Purl::License::Plans::features_for($plan) } ],
            [ sort @{ $WEB_FEATURE_IDS{$plan} } ],
            "$plan feature IDs identical to the license issuer's";
    }

    is_deeply
        [ sort @{ Purl::License::Plans::features_for('trial') } ],
        [ sort @{ $WEB_FEATURE_IDS{pro} } ],
        'trial grants exactly Pro (paying can never remove a feature)';

    is_deeply
        Purl::License::Plans::unlimited_limits(),
        { servers => -1, agents => -1, users => -1, alerts => -1,
          saved_searches => -1 },
        'every metered resource is unlimited (-1) on every plan we sell';
};

# Every gate name that actually appears in lib/ must be sold by SOME plan.
# A require_feature('foo') whose name no plan grants is a permanent 403 for
# every paying customer — the exact shape of the bug this file exists to stop.
# Enterprise is the superset, so membership there is the test.
subtest 'every feature gate in lib/ is granted by at least one plan' => sub {
    my %sellable = map { $_ => 1 } @{ $WEB_FEATURE_IDS{enterprise} };

    my @sources;
    my $scan;
    $scan = sub {
        my ($dir) = @_;
        opendir my $dh, $dir or die "opendir $dir: $!";
        for my $entry (sort grep { !/^\.\.?$/ } readdir $dh) {
            my $path = File::Spec->catfile($dir, $entry);
            if    (-d $path)          { $scan->($path) }
            elsif ($path =~ /\.pm$/)  { push @sources, $path }
        }
        closedir $dh;
        return;
    };
    $scan->(File::Spec->catdir($Bin, '..', 'lib'));
    ok scalar @sources, 'found Perl modules to scan';

    my %gates;
    for my $file (@sources) {
        open my $fh, '<', $file or die "open $file: $!";
        while (my $line = <$fh>) {
            # Both gate helpers: require_feature renders a 403, has_feature is
            # the silent variant used on the ingest path.
            while ($line =~ /(?:require|has)_feature\(\s*\$c\s*,\s*'([a-z0-9_]+)'/g) {
                $gates{$1} //= $file;
            }
        }
        close $fh;
    }

    ok scalar(keys %gates) >= 14, 'found the known feature gates in lib/'
        or diag 'gates seen: ' . join(', ', sort keys %gates);

    for my $gate (sort keys %gates) {
        ok $sellable{$gate},
            "gate '$gate' ($gates{$gate}) is granted by a plan we sell";
    }
};

# ---------------------------------------------------------------------------
# 8. The 'dashboards' alias — purl-web has issued keys naming it
#    'custom_dashboards'. Both names must open the same gate.
# ---------------------------------------------------------------------------
subtest 'dashboards gate accepts the custom_dashboards alias' => sub {
    my $now = time();
    my $aliased = Crypt::JWT::encode_jwt(
        payload => {
            iss => 'purl', sub => 'u', aud => 'self-hosted',
            iat => $now, exp => $now + 86400, jti => 'alias',
            plan     => 'pro',
            limits   => { servers => -1, agents => -1, users => -1, alerts => -1 },
            features => [ 'log_search', 'custom_dashboards' ],   # legacy name only
            customerEmail => 'legacy@example.com',
        },
        key => \$PRIVATE_PEM,
        alg => 'RS256',
    );

    $ENV{PURL_LICENSE_KEY} = $aliased;
    $license_mw->_license_info(undef);
    $license_mw->_cache_expires(0);

    $t->get_ok('/api/dashboards', \%HDR)->status_is(200);

    # ...and a feature the aliased key genuinely lacks is still refused, so the
    # alias bridges a NAME mismatch and does not become a blanket bypass.
    $t->get_ok('/api/pipelines', \%HDR)->status_is(403)
      ->json_is('/feature' => 'pipelines');
};

# ---------------------------------------------------------------------------
# 9. Unlimited (-1) quotas over HTTP
#
# Regression: an open-coded `$count >= $max` reads `0 >= -1` as TRUE, so a plan
# advertising unlimited allowed NOTHING to be created. t/license_quota_limits.t
# pins check_limit itself; this pins the real endpoints behind real licenses.
# ---------------------------------------------------------------------------
for my $plan (qw(free pro enterprise)) {
    subtest "plan=$plan honours unlimited (-1) quotas over HTTP" => sub {
        activate_plan($plan);

        for my $n (1 .. 3) {
            $t->post_ok('/api/settings/users', \%HDR,
                json => { username => "user_${plan}_$n", password => 'longenough1' })
              ->status_is(200);

            $t->post_ok('/api/alerts', \%HDR,
                json => { name => "alert_${plan}_$n", notify_type => 'browser' })
              ->status_is(200);

            $t->post_ok('/api/agents/register', \%HDR,
                json => { hostname => "host-${plan}-$n" })
              ->status_is(200);

            $t->post_ok('/api/saved-searches', \%HDR,
                json => { name => "ss_${plan}_$n", query => 'level:ERROR' })
              ->status_is(200);
        }

        $t->get_ok('/api/agents', \%HDR)->status_is(200)
          ->json_is('/limit/max' => -1, 'agents limit reported as unlimited');
    };
}

# ---------------------------------------------------------------------------
# 10. Invalid / expired keys degrade to Free — never to "everything allowed"
# ---------------------------------------------------------------------------
subtest 'an expired license key falls back to Free, not to Pro' => sub {
    $ENV{PURL_LICENSE_KEY} = Crypt::JWT::encode_jwt(
        payload => {
            iss => 'purl', sub => 'u', aud => 'self-hosted',
            iat => time() - 100_000, exp => time() - 10, jti => 'expired',
            plan => 'enterprise', limits => {},
            features => [ @{ $WEB_FEATURE_IDS{enterprise} } ],
            customerEmail => 'lapsed@example.com',
        },
        key => \$PRIVATE_PEM, alg => 'RS256',
    );
    $license_mw->_license_info(undef);
    $license_mw->_cache_expires(0);

    $t->get_ok('/api/dashboards', \%HDR)->status_is(403)
      ->json_is('/feature' => 'dashboards');
    $t->get_ok('/api/audit', \%HDR)->status_is(403)
      ->json_is('/feature' => 'audit_logs');
};

subtest 'a key signed by the wrong private key grants nothing' => sub {
    my $attacker = Crypt::PK::RSA->new;
    $attacker->generate_key(256, 65537);

    $ENV{PURL_LICENSE_KEY} = Crypt::JWT::encode_jwt(
        payload => {
            iss => 'purl', sub => 'u', aud => 'self-hosted',
            iat => time(), exp => time() + 86400, jti => 'forged',
            plan => 'enterprise', limits => {},
            features => [ @{ $WEB_FEATURE_IDS{enterprise} } ],
            customerEmail => 'forger@example.com',
        },
        key => \(my $forged_pem = $attacker->export_key_pem('private')),
        alg => 'RS256',
    );
    $license_mw->_license_info(undef);
    $license_mw->_cache_expires(0);

    $t->get_ok('/api/audit', \%HDR)->status_is(403)
      ->json_is('/feature' => 'audit_logs');
    $t->get_ok('/api/patterns', \%HDR)->status_is(200);   # Free still works
};

done_testing();

package PurlTest::SessionApp;
use strict;
use warnings;
use 5.024;

# ============================================
# The REAL Purl app over Test::Mojo, with auth on and a throwaway config dir,
# for the session / principal / revocation tests. Several test files drive the
# same login -> capture cookie -> replay flow; the harness lives here once.
#
# Loading this module sets the environment (before Purl::API::Server is
# loaded), so `use PurlTest::SessionApp` must come before anything that loads
# the server. Seeded accounts: admin / StrongAdminPass123.
# ============================================

use Exporter 'import';
use File::Temp qw(tempdir);
use POSIX ();
use Mojo::JSON qw(encode_json decode_json);

our @EXPORT_OK = qw(
    config_dir storage build_app app csrf login cookie_of replay forge_cookie
    admin_call in_child with_csrf
);

my $DIR;
BEGIN {
    $DIR = tempdir(CLEANUP => 1);
    $ENV{PURL_AUTH_ENABLED}    = '1';
    $ENV{PURL_ADMIN_PASSWORD}  = 'StrongAdminPass123';
    $ENV{PURL_LDAP_ENABLED}    = '0';
    $ENV{PURL_SAML_ENABLED}    = '0';
    $ENV{PURL_SESSION_SECRET}  = 'session-revocation-test-secret-0123456789';
    $ENV{PURL_CONFIG_FILE}     = "$DIR/settings.json";
    $ENV{PURL_CONFIG_DIR}      = $DIR;
    $ENV{PURL_CLICKHOUSE_HOST} = '127.0.0.1';
    $ENV{PURL_CLICKHOUSE_PORT} = '19999';               # unlikely to be up
    delete $ENV{PURL_API_KEYS};
    delete $ENV{PURL_SESSION_MAX_AGE};
}

use PurlTest::Mock qw(mock_server_storage);
require Purl::API::Server;

# One storage per process, so a test can read the audit events it recorded.
my $STORAGE = mock_server_storage();
{
    no warnings 'redefine';
    *Purl::API::Server::_build_storage = sub { return $STORAGE };
}

use Test::More ();
use Test::Mojo;

sub config_dir { return $DIR }
sub storage    { return $STORAGE }

# One app = one worker/replica: its own Purl::Config, its own middleware.
# Audit events reach $STORAGE through the server's own wiring (#101): the
# harness deliberately adds no helper of its own.
sub build_app {
    my $server = Purl::API::Server->create(config => { auth => { enabled => 1 } });
    return $server->setup_routes;
}

my $APP;
sub app { return $APP //= build_app() }

sub csrf {
    my ($t) = @_;
    $t->get_ok('/api/csrf-token');
    return $t->tx->res->json->{csrf_token};
}

sub login {
    my ($user, $pass, $on) = @_;
    my $t = Test::Mojo->new($on // app());
    $t->post_ok('/api/auth/login', json => { username => $user, password => $pass })
      ->status_is(200)->json_is('/authenticated' => 1);
    return $t;
}

# The raw session cookie as the browser would send it.
sub cookie_of {
    my ($t) = @_;
    my ($ck) = grep { $_->name eq 'mojolicious' } @{ $t->ua->cookie_jar->all };
    return $ck ? $ck->name . '=' . $ck->value : undef;
}

# Replay a captured cookie from a client with no jar of its own. Returns
# (me.authenticated, status of a protected GET).
sub replay {
    my ($cookie, $on) = @_;
    my $t = Test::Mojo->new($on // app());
    $t->ua->cookie_jar->ignore(sub { 1 });
    my $me = $t->get_ok('/api/auth/me', { Cookie => $cookie })->tx->res->json->{authenticated};
    my $st = $t->get_ok('/api/alerts', { Cookie => $cookie })->tx->res->code;
    return ($me, $st);
}

# Sign an arbitrary session exactly the way the app does, so a cookie from
# before #91 (or with a chosen iat) can be presented.
sub forge_cookie {
    my (%session) = @_;
    my $c = app()->build_controller;
    %{ $c->session } = %session;
    $c->session(expiration => 86400);
    app()->sessions->store($c);
    my ($ck) = grep { $_->name eq 'mojolicious' } @{ $c->res->cookies };
    return $ck->name . '=' . $ck->value;
}

# Request headers carrying a valid CSRF token, plus any given. For a request
# that has no Test::Mojo of its own to fetch one (a replayed cookie, a child
# process). The token is signed with the shared session secret, as every
# worker and replica signs it.
sub with_csrf {
    my (%h) = @_;
    require Purl::API::Middleware::Auth;
    $h{'X-CSRF-Token'} = Purl::API::Middleware::Auth->new(config => {})->generate_csrf_token;
    return \%h;
}

# Sign in as admin and make one CSRF-protected call; returns the Test::Mojo.
sub admin_call {
    my ($method, $path, $body, $status) = @_;
    my $t = login('admin', 'StrongAdminPass123');
    my $m = "${method}_ok";
    $t->$m($path, { 'X-CSRF-Token' => csrf($t) }, $body ? (json => $body) : ())
      ->status_is($status // 200);
    return $t;
}

# Run $code in a forked child and return the one line it produced (decoded
# JSON). The child exits without END blocks: the parent owns the temp dir.
sub in_child {
    my ($code) = @_;
    pipe(my $r, my $w) or die $!;
    my $pid = fork() // die "fork: $!";
    if (!$pid) {
        close $r;
        my $out = eval { $code->() };
        $out = { error => "$@" } unless defined $out;
        syswrite $w, encode_json($out) . "\n";
        POSIX::_exit(0);
    }
    close $w;
    my $line = <$r>;
    waitpid $pid, 0;
    return $line ? decode_json($line) : { error => 'child died' };
}

1;

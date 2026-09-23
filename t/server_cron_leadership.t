use strict;
use warnings;
use 5.024;

use Test::More;
use File::Spec ();
use POSIX ();

# ============================================================
# Prefork singleton-cron leadership.
#
# In prefork, setup_routes() registers the recurring timers in the manager
# BEFORE fork, so every worker inherits them. Host-wide singleton jobs
# (scheduled backup, alert evaluation) must run in EXACTLY ONE process. We
# gate them behind Purl::API::Server::Cron::acquire_leadership(), which lets
# exactly one process hold an exclusive advisory lock at a time and is
# self-healing when the holder dies.
#
# NOTE ON SCOPE: the actual prefork timer *placement* (that the manager never
# runs its IOLoop, so pre-fork timers fire once per worker) is verified by
# code-reading, not here -- forking a real N-worker server and counting
# heartbeats over a 6h interval is not unit-testable. What IS unit-testable,
# and what this file proves, is the gate that guarantees "run in exactly one
# process": mutual exclusion + self-healing takeover after the leader dies.
# ============================================================

require Purl::API::Server::Cron;

my $lock = File::Spec->catfile(File::Spec->tmpdir, "purl-cron-lead-$$.lock");
unlink $lock;

# Reset any leadership state this process may have picked up.
$Purl::API::Server::Cron::CRON_LEADER_FH = undef;

# ------------------------------------------------------------
# 1. Fresh acquire -> this process becomes leader.
# ------------------------------------------------------------
ok(Purl::API::Server::Cron::acquire_leadership($lock),
    'fresh acquire returns true (became cron leader)');
ok(defined $Purl::API::Server::Cron::CRON_LEADER_FH,
    'leader holds the lock descriptor open');

# ------------------------------------------------------------
# 2. Idempotent -> calling again while leader stays true, no reopen.
# ------------------------------------------------------------
my $fh_before = $Purl::API::Server::Cron::CRON_LEADER_FH;
ok(Purl::API::Server::Cron::acquire_leadership($lock),
    'second call while already leader returns true');
is($Purl::API::Server::Cron::CRON_LEADER_FH, $fh_before,
    'idempotent: descriptor not reopened on repeat acquire');

# ------------------------------------------------------------
# 3. Mutual exclusion -> a second, independent process CANNOT acquire while
#    this process holds the lock. (This is the "run in exactly one place"
#    guarantee for the prefork workers.)
# ------------------------------------------------------------
{
    my $pid = fork();
    if (!defined $pid) {
        diag("fork failed: $! -- skipping mutual-exclusion check");
    }
    elsif ($pid == 0) {
        # Child: drop the inherited "already leader" flag so we genuinely
        # re-attempt the flock against the parent's held lock.
        $Purl::API::Server::Cron::CRON_LEADER_FH = undef;
        my $got = Purl::API::Server::Cron::acquire_leadership($lock);
        # exit 0 == correctly DENIED, exit 1 == wrongly acquired.
        POSIX::_exit($got ? 1 : 0);
    }
    else {
        waitpid($pid, 0);
        is($? >> 8, 0,
            'a second process is DENIED leadership while the first holds it (exactly-one-leader)');
    }
}

# ------------------------------------------------------------
# 4. Self-healing takeover -> after the leader "dies" (releases the lock),
#    another process CAN acquire it. This is the failover behaviour the
#    30s election tick relies on.
# ------------------------------------------------------------
close $Purl::API::Server::Cron::CRON_LEADER_FH if $Purl::API::Server::Cron::CRON_LEADER_FH;
$Purl::API::Server::Cron::CRON_LEADER_FH = undef;   # simulate leader process exit

{
    my $pid = fork();
    if (!defined $pid) {
        diag("fork failed: $! -- skipping takeover check");
    }
    elsif ($pid == 0) {
        $Purl::API::Server::Cron::CRON_LEADER_FH = undef;
        my $got = Purl::API::Server::Cron::acquire_leadership($lock);
        POSIX::_exit($got ? 0 : 1);   # exit 0 == successfully took over
    }
    else {
        waitpid($pid, 0);
        is($? >> 8, 0,
            'after the leader releases, a new process acquires leadership (self-healing takeover)');
    }
}

# ------------------------------------------------------------
# 5. Lock-path resolution honours PURL_CRON_LOCK_FILE override.
# ------------------------------------------------------------
{
    local $ENV{PURL_CRON_LOCK_FILE} = '/some/custom/purl.lock';
    is(Purl::API::Server::Cron::cron_lock_path(), '/some/custom/purl.lock',
        'PURL_CRON_LOCK_FILE overrides the default lock path');
}
like(Purl::API::Server::Cron::cron_lock_path(), qr/purl-cron-leader\.lock$/,
    'default lock path falls back to tmpdir/purl-cron-leader.lock');

unlink $lock;
done_testing;

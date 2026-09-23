package Purl::API::Server::Cron;
use strict;
use warnings;
use 5.024;

use Fcntl qw(:flock);
use File::Spec ();
use Mojo::IOLoop ();

# ---------------------------------------------------------------------------
# Recurring server jobs and singleton cron leadership (prefork-safe)
#
# register_timers() runs in the prefork MANAGER, *before* build_prefork->run
# forks the workers. Any Mojo::IOLoop->recurring timer registered there is
# inherited by EVERY worker's event loop (the manager itself never starts its
# IOLoop -- it runs Mojo::Server::Prefork::_manage, a blocking manage/wait
# loop). So a host-wide singleton job (e.g. scheduled backup) registered
# pre-fork would fire once PER WORKER: N concurrent backups racing on the same dir / S3 prefix.
#
# We keep registering the timers pre-fork (so they exist in each worker) but
# gate the actual work behind an exclusive advisory file lock: exactly one
# worker can hold LOCK_EX at a time, and that worker becomes the "cron leader".
# The holder keeps the descriptor open for its lifetime. If it dies, the OS
# releases the lock automatically and another worker acquires it on its next
# election tick -- no manager<->worker IPC required, and self-healing.
#
# The per-worker 2s ingest-buffer flush is intentionally NOT gated (each worker
# owns its own buffer and must flush it).
# ---------------------------------------------------------------------------
our $CRON_LEADER_FH;   # defined only in the worker currently holding the lock

sub cron_lock_path {
    return $ENV{PURL_CRON_LOCK_FILE}
        // File::Spec->catfile(File::Spec->tmpdir, 'purl-cron-leader.lock');
}

# Try to become (or confirm we already are) the singleton cron leader.
# Returns true iff THIS process currently holds the exclusive lock.
# $log (optional) receives the open-failure warning; without one it is warn()ed.
sub acquire_leadership {
    my ($lock_path, $log) = @_;
    $lock_path //= cron_lock_path();

    # Already leader: keep the descriptor open, stay leader.
    return 1 if $CRON_LEADER_FH;

    open my $fh, '>', $lock_path
        or do {
            my $msg = "Cron lock open failed ($lock_path): $!";
            $log ? $log->warn($msg) : warn "$msg\n";
            return 0;
        };

    if (flock $fh, LOCK_EX | LOCK_NB) {
        $CRON_LEADER_FH = $fh;   # hold the lock for our process lifetime
        return 1;
    }

    close $fh;
    return 0;
}

# ============================================
# Server-side alert evaluation
# ============================================

# Resolve how often the alert timer runs, in seconds.
# ENV PURL_ALERT_CHECK_INTERVAL > settings alerts.check_interval_seconds > 60.
# Returns 0 to mean "disabled" (explicit 0, or any non-numeric/negative value).
# Values below MIN are raised to MIN: check_alerts() is a full pass over every
# alert rule against ClickHouse, so a 1s interval would be self-inflicted DoS.
my $ALERT_CHECK_MIN_INTERVAL = 10;

sub alert_check_interval {
    my ($settings) = @_;

    # Go through Config::get rather than reading %ENV directly: it already owns
    # the ENV>settings>default precedence via %ENV_MAP and already treats an
    # empty-but-present env var as unset. Reading $ENV here instead made
    # PURL_ALERT_CHECK_INTERVAL="" — the normal result of templating an unset
    # Helm value — silently disable all alerting.
    my $raw = $settings ? $settings->get('alerts', 'check_interval_seconds') : undef;
    $raw = undef if defined $raw && $raw =~ /^\s*$/;
    $raw //= 60;

    $raw =~ s/^\s+|\s+$//g;
    return 0 unless $raw =~ /^\d+$/;
    return 0 if $raw == 0;
    return $raw < $ALERT_CHECK_MIN_INTERVAL ? $ALERT_CHECK_MIN_INTERVAL : $raw;
}

# One leader-gated alert evaluation tick.
#
# Returns undef when this process is NOT the cron leader — i.e. the check did
# not run here, which is exactly what stops N prefork workers from firing N
# duplicate Telegram messages. Otherwise returns the Scheduler result hashref,
# with an extra {error} key if evaluation threw (never propagates: a failing
# ClickHouse must not kill the IOLoop timer).
sub run_alert_check {
    my ($scheduler, $lock_path, $log) = @_;
    return undef unless $scheduler;
    return undef unless acquire_leadership($lock_path, $log);

    my $result = eval { $scheduler->run_once() };
    return $result if ref $result eq 'HASH';
    return { triggered => [], notifications => [], error => ($@ || 'unknown error') };
}

# Register every recurring server job. Called once from setup_routes(), in the
# manager, before fork (see the header above). %args:
#   log             Mojo::Log
#   settings        Purl::Config (may be undef)
#   storage         coderef returning the CURRENT storage (it can be rebuilt
#                   by a settings change, so it is read on every tick)
#   alert_scheduler Purl::Alert::Scheduler used by the alert tick
sub register_timers {
    my (%args) = @_;
    my $log       = $args{log};
    my $settings  = $args{settings};
    my $storage   = $args{storage};

    # Periodic buffer flush -- DELIBERATELY per-worker. Each prefork worker owns
    # its own ingest buffer, so this MUST fire in EVERY worker. Do NOT gate it
    # behind cron leadership.
    Mojo::IOLoop->recurring(2 => sub {
        my $st = $storage->();
        if ($st && $st->can('maybe_flush')) {
            eval { $st->maybe_flush(); };
            $log->error("Periodic buffer flush failed: $@") if $@;
        }
    });

    # Cron leader election / takeover tick. Cheap: one flock attempt while we
    # are not the leader, an immediate return once we are. Runs in every worker
    # so that if the current leader dies (OS drops its lock) another worker
    # takes over within one interval. See acquire_leadership().
    my $cron_lock_path = cron_lock_path();
    Mojo::IOLoop->recurring(30 => sub {
        acquire_leadership($cron_lock_path, $log);
    });

    _register_backup_timer($log, $settings, $storage, $cron_lock_path);
    _register_alert_timer($log, $settings, $args{alert_scheduler}, $cron_lock_path);
    return;
}

# Scheduled backup (configurable interval, disabled by default)
sub _register_backup_timer {
    my ($log, $settings, $storage, $cron_lock_path) = @_;

    my $backup_schedule_enabled = $ENV{PURL_BACKUP_SCHEDULE_ENABLED}
        // ($settings ? $settings->get('backup', 'schedule_enabled') : 0);
    return unless $backup_schedule_enabled;

    my $backup_interval_hours = $ENV{PURL_BACKUP_SCHEDULE_INTERVAL_HOURS}
        // ($settings ? $settings->get('backup', 'schedule_interval_hours') : 24);
    my $backup_retention_days = $ENV{PURL_BACKUP_RETENTION_DAYS}
        // ($settings ? $settings->get('backup', 'retention_days') : 30);
    my $backup_dir = $ENV{PURL_BACKUP_DIR} // '/app/backups';
    my $interval_seconds = $backup_interval_hours * 3600;

    $log->info("Scheduled backup enabled: every ${backup_interval_hours}h, retention ${backup_retention_days}d");

    # SINGLETON: leader worker only, so N workers do not launch N
    # concurrent backups racing on the same dir / S3 prefix (and one
    # worker's cleanup_old_backups cannot delete a backup another is
    # still writing).
    Mojo::IOLoop->recurring($interval_seconds => sub {
        return unless acquire_leadership($cron_lock_path, $log);
        my $st = $storage->();
        eval {
            require POSIX;
            $log->info("Starting scheduled backup...");
            my $result = $st->create_backup(
                name       => 'scheduled_' . POSIX::strftime('%Y%m%d_%H%M%S', localtime),
                backup_dir => $backup_dir,
            );
            $log->info("Scheduled backup completed: id=$result->{id}, size=$result->{size_bytes}");

            # Auto-upload to S3 if enabled. Config resolution lives in
            # Purl::Storage::S3 so the scheduler, the controller and the
            # storage layer all agree on one bucket.
            require Purl::Storage::S3;
            my $s3_config = Purl::Storage::S3->config_from(settings => $settings);
            if ($s3_config->{enabled}) {
                eval {
                    my $s3_result = $st->upload_backup_to_s3($result->{id}, $s3_config);
                    $log->info("Backup uploaded to S3: $s3_result->{target_path}");
                };
                $log->error("S3 upload failed: $@") if $@;
            }

            # Auto-cleanup old backups. s3_config is passed so expired
            # backups are removed from the bucket too, not just from the
            # metadata table.
            my $cleaned = $st->cleanup_old_backups(
                $backup_retention_days,
                s3_config => $s3_config,
            );
            $log->info("Cleaned up $cleaned old backups") if $cleaned > 0;
        };
        $log->error("Scheduled backup failed: $@") if $@;
    });
    return;
}

# Server-side alert evaluation.
#
# Without this timer check_alerts() ran ONLY from POST /api/alerts/check,
# which only the dashboard calls — so closing the browser tab silently
# stopped every Telegram/Slack/webhook notification. Alerting is a server
# responsibility, not a browser one.
#
# SINGLETON: leader worker only (same gate as the backup timer), otherwise
# N workers would each evaluate every rule and fire N duplicate messages.
sub _register_alert_timer {
    my ($log, $settings, $alert_scheduler, $cron_lock_path) = @_;

    my $alert_interval = alert_check_interval($settings);
    unless ($alert_interval) {
        $log->info('Server-side alert checks DISABLED (alerts.check_interval_seconds = 0)');
        return;
    }

    $log->info("Server-side alert checks enabled: every ${alert_interval}s");
    # Evaluation and fan-out are both BLOCKING: check_alerts() is a
    # synchronous ClickHouse query and every notifier is a synchronous
    # HTTP::Tiny post (Telegram's timeout alone is 10s). Running that
    # inline would freeze the leader worker's event loop for the whole
    # tick — no requests served, no ingest buffer flushed, no WebSocket
    # serviced — for up to timeout x triggered-alert-count. A subprocess
    # keeps the blocking work off the loop; the leader lock is acquired in
    # the child so a stuck tick cannot also hold leadership hostage.
    my $alert_tick_running = 0;
    Mojo::IOLoop->recurring($alert_interval => sub {
        # Never overlap ticks: a fan-out slower than the interval would
        # otherwise pile up subprocesses and re-send the same alerts.
        return if $alert_tick_running;
        $alert_tick_running = 1;

        Mojo::IOLoop->subprocess(
            sub {
                my $result = run_alert_check($alert_scheduler, $cron_lock_path, $log);
                return $result // { skipped => 1 };
            },
            sub {
                my ($subprocess, $err, $result) = @_;
                $alert_tick_running = 0;

                if ($err) {
                    $log->error("Scheduled alert check subprocess failed: $err");
                    return;
                }
                return unless ref $result eq 'HASH';
                return if $result->{skipped};     # not the leader this tick
                if (my $rerr = $result->{error}) {
                    $log->error("Scheduled alert check failed: $rerr");
                    return;
                }
                my $n = scalar @{ $result->{notifications} // [] };
                $log->info("Scheduled alert check sent $n notification(s)") if $n;
            }
        );
    });
    return;
}

1;

__END__

=head1 NAME

Purl::API::Server::Cron - recurring server jobs (ingest flush, scheduled
backup, server-side alert checks) and prefork-safe singleton cron leadership

=cut

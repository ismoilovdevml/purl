use strict;
use warnings;
use 5.024;

use Test::More;
use Time::HiRes qw(time);

use Purl::Pipeline::Engine;

# ============================================================
# ReDoS guard tests for Purl::Pipeline::Engine
#
# The engine compiles USER-SUPPLIED regexes. Without a guard a
# catastrophic-backtracking pattern pegs the CPU and (server is
# single-process/single-threaded) hangs the whole process.
#
# On this Perl build (5.42) the classic textbook patterns like
# (a+)+$ are neutralised by the WHILEM super-linear cache, but a
# BACKREFERENCE pattern such as ^(a+)+\1$ still blows up
# exponentially (n=28 -> ~13s unguarded). We use that as the
# real-world catastrophic case.
# ============================================================

my $CATASTROPHIC = '^(a+)+\1$';
my $EVIL_INPUT   = ('a' x 30) . 'b';   # forced non-match, >10s unguarded

# Small timeout so the test itself is fast.
my $TIMEOUT_MS = 200;

my $engine = Purl::Pipeline::Engine->new(
    regex_timeout_ms => $TIMEOUT_MS,
    regex_max_length => 512,
);

# ------------------------------------------------------------
# 1. THE MAIN EVENT: catastrophic pattern must ABORT under the
#    timeout, not hang. Wall-clock assertion included.
# ------------------------------------------------------------
{
    my $pipeline = {
        rules => [
            { type => 'regex', source_field => 'message', pattern => $CATASTROPHIC },
        ],
    };
    my $samples = [ { message => $EVIL_INPUT } ];

    my $t0 = time;
    my $results = $engine->test_pipeline($pipeline, $samples);
    my $elapsed = time - $t0;

    ok(defined $results, 'engine returned instead of hanging on catastrophic regex');
    cmp_ok($elapsed, '<', 1.0,
        sprintf('catastrophic regex aborted in %.3fs (well under 1s wall-clock)', $elapsed));

    my $res = $results->[0];
    ok($res->{errors} && @{ $res->{errors} },
        'timeout surfaced as a clean per-result error to the caller');
    like($res->{errors}[0]{error}, qr/timed out|timeout/i,
        'error message identifies the timeout');
    # The worker did not crash: output is still present (pass-through).
    ok(defined $res->{output}, 'log passed through unharmed after regex timeout');
}

# ------------------------------------------------------------
# 2. process() (real ingest path) must also survive the bomb.
# ------------------------------------------------------------
{
    $engine->pipelines([
        {
            enabled => 1,
            rules   => [
                { type => 'regex', enabled => 1, source_field => 'message', pattern => $CATASTROPHIC },
            ],
        },
    ]);

    my $t0 = time;
    my $out = $engine->process({ message => $EVIL_INPUT, service => 'svc' });
    my $elapsed = time - $t0;

    cmp_ok($elapsed, '<', 1.0,
        sprintf('process() aborted catastrophic regex in %.3fs', $elapsed));
    ok(defined $out, 'process() did not drop/crash the log on regex timeout');
    is($out->{message}, $EVIL_INPUT, 'process() preserved the original log');

    $engine->pipelines([]);   # reset
}

# ------------------------------------------------------------
# 3. A malicious pattern in a DROP rule must not drop the log on
#    timeout (fail-safe: keep data rather than silently discard).
# ------------------------------------------------------------
{
    my $pipeline = {
        rules => [
            { type => 'drop', field => 'message', pattern => $CATASTROPHIC },
        ],
    };
    my $results = $engine->test_pipeline($pipeline, [ { message => $EVIL_INPUT } ]);
    ok(!$results->[0]{dropped}, 'log NOT dropped when drop-rule regex times out');
    ok($results->[0]{errors} && @{ $results->[0]{errors} },
        'drop-rule timeout surfaced as error');
}

# ------------------------------------------------------------
# 4. Pattern length bound: absurdly long patterns rejected before
#    compilation, cleanly.
# ------------------------------------------------------------
{
    my $short_engine = Purl::Pipeline::Engine->new(
        regex_timeout_ms => $TIMEOUT_MS,
        regex_max_length => 16,
    );
    my $long_pattern = 'a' x 100;
    my $pipeline = {
        rules => [ { type => 'regex', source_field => 'message', pattern => $long_pattern } ],
    };
    my $results = $short_engine->test_pipeline($pipeline, [ { message => 'aaaa' } ]);
    ok($results->[0]{errors} && @{ $results->[0]{errors} },
        'over-length pattern rejected with an error');
    like($results->[0]{errors}[0]{error}, qr/length/i,
        'rejection message mentions length');
}

# ------------------------------------------------------------
# 5. Invalid pattern returns a clean error, never crashes worker.
# ------------------------------------------------------------
{
    my $pipeline = {
        rules => [ { type => 'regex', source_field => 'message', pattern => '(unclosed' } ],
    };
    my $results;
    my $lived = eval {
        $results = $engine->test_pipeline($pipeline, [ { message => 'hello' } ]);
        1;
    };
    ok($lived, 'invalid pattern did not crash the engine');
    ok($results->[0]{errors} && @{ $results->[0]{errors} },
        'invalid pattern surfaced as a clean error');
    like($results->[0]{errors}[0]{error}, qr/invalid/i, 'error labelled invalid pattern');
}

# ------------------------------------------------------------
# 6. Sanity: a normal, safe pattern still works end-to-end.
# ------------------------------------------------------------
{
    my $pipeline = {
        rules => [
            {
                type         => 'regex',
                source_field => 'message',
                pattern      => 'user=(?<user>\w+)',
            },
        ],
    };
    my $results = $engine->test_pipeline($pipeline, [ { message => 'login user=alice ok' } ]);
    ok(!($results->[0]{errors} && @{ $results->[0]{errors} }),
        'valid pattern produces no error');
    is($results->[0]{output}{meta}{user}, 'alice',
        'valid named capture still extracted correctly');
}

# ------------------------------------------------------------
# 7. Safe grok pattern still functions under the guard.
# ------------------------------------------------------------
{
    my $pipeline = {
        rules => [
            { type => 'grok', source_field => 'message', pattern => 'ip=%{IP:ip}' },
        ],
    };
    my $results = $engine->test_pipeline($pipeline, [ { message => 'ip=10.0.0.5' } ]);
    is($results->[0]{output}{meta}{ip}, '10.0.0.5', 'grok extraction still works');
}

done_testing();

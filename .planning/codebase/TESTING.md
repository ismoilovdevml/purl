# Testing Patterns

**Analysis Date:** 2026-03-10

## Test Framework

**Runner:**
- Framework: `prove` (Perl's Test Harness)
- Version: Built into Perl 5.40 / Purl uses system prove
- Config: None (uses defaults; runs all `*.t` files in `t/` directory)
- Command: `prove -r t/` (run all tests recursively)

**Assertion Library:**
- `Test::More` (standard Perl testing module)
- Assertions: `ok()`, `is()`, `isnt()`, `like()`, `unlike()`, `can_ok()`, `isa_ok()`, `subtest()`

**Run Commands:**
```bash
make test              # Run all tests: prove -r t/ 2>/dev/null
make preflight         # Full verification: lint + test + build
```

Coverage: No coverage tool configured (no .coveragerc, no nyc, no Devel::Cover)

## Test File Organization

**Location:**
- All tests in `t/` directory at project root
- Co-located: `t/01_time_util.t` tests `lib/Purl/Util/Time.pm`
- Pattern: `t/{number}_{module_under_test}.t` or `t/{category}/{test_name}.t`

**Naming:**
- Numbered prefix for execution order: `t/01_time_util.t`, `t/02_config.t`, `t/06_middleware_auth.t`
- Descriptive suffixes: `controller_logs.t`, `middleware_auth.t`, `alert_webhook.t`
- Subdirectories by category: `t/controller/`, `t/` (root for legacy)

**File count:** 36 test files, ~9945 lines of test code total

**Structure:**
```
t/
├── 01_time_util.t              # Utility tests
├── 02_config.t                 # Configuration
├── 03_modules_load.t           # Module loading verification
├── 06_middleware_auth.t        # Middleware tests
├── 07_middleware_functional.t
├── 08_middleware_license.t
├── 14_controller_logs.t        # Controller tests
├── 18_controller_traces.t
├── 19_controller_patterns.t
├── controller/                 # Newer tests (subdirectory)
│   ├── agents.t
│   ├── alert_templates.t
│   ├── clusters.t
│   └── ...
└── ...
```

## Test Structure

**Suite Organization (typical from `t/01_time_util.t`):**
```perl
#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use_ok('Purl::Util::Time', qw(
    epoch_to_iso
    parse_time_range
    format_duration
    ...
));

# Simple function tests
is(epoch_to_iso(0), '1970-01-01T00:00:00Z', 'epoch 0 → Unix epoch');

# Block with grouped assertions
{
    my ($from, $to) = parse_time_range('15m');
    ok(defined $from && defined $to, '15m returns two timestamps');
    like($from, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, '15m from is ISO8601');
}

# Subtest for organization
subtest 'hash_password validation' => sub {
    my $hash = $auth->hash_password('secretpass');
    ok defined $hash, 'hash returned';
    like $hash, qr/^\$2[aby]\$12\$.+$/, 'bcrypt format';
};

done_testing();
```

**Key patterns:**
- Each file starts with `use strict; use warnings; use Test::More;`
- `use FindBin` and `use lib` to add project lib to @INC
- `use_ok()` to verify module loads
- Test descriptions in second argument: `is($actual, $expected, 'description')`
- Blocking for organization: `{ ... }` creates lexical scope (local variables)
- `subtest()` for nested test suites
- `done_testing()` at end (no plan declared)

## Test Structure (Mocking Pattern)

**Mock objects (from `t/14_controller_logs.t`):**
```perl
package MockCtrl;
sub new {
    bless {
        req      => MockReq->new($_[1], $_[2], $_[3]),
        res      => MockRes->new,
        rendered => undef,
        stash    => $_[4] // {},
        session  => {},
        params   => $_[2] // {},
        app      => MockApp->new,
    }, $_[0];
}
sub req { $_[0]->{req} }
sub res { $_[0]->{res} }
sub render {
    my ($self, %args) = @_;
    $self->{rendered} = \%args;
}
```

**Pattern:**
- Mock objects defined as `package NameInTest { ... }` inside test file (not separate)
- Minimal interface: only methods being tested
- State captured for assertion: `$self->{rendered}` stores what was rendered
- Created inline: `my $c = MockCtrl->new(body, params, headers, stash);`

## Mocking

**Framework:**
- No dedicated mocking library (Test::Mock::*)
- All mocks written by hand in test files
- Pragmatic: Each test writes the mock objects it needs

**Patterns (Setup):**
```perl
# Object creation
my $auth = Purl::API::Middleware::Auth->new;

# Mock controller
package MockCtrl;
sub new { bless { ... }, $_[0] }
```

**Patterns (Verification):**
```perl
# State-based verification
my $ctrl = MockCtrl->new(...);
$controller->login($ctrl);
is($ctrl->{session}{username}, 'admin', 'username set in session');

# Call recording (rarely used)
package MockStorage;
sub search {
    my ($self, %params) = @_;
    $self->{calls}{search} = \%params;  # Record what was passed
    return $self->{search_result} // [];
}
```

**What to Mock:**
- External dependencies: ClickHouse queries (MockStorage), HTTP calls (not mocked — tested against real services in integration tests)
- Database: `MockStorage` object with `search()`, `insert()`, `count()` methods
- Request/Response objects: `MockCtrl`, `MockReq`, `MockRes` for controller tests
- Controllers: Real objects tested with mocked storage

**What NOT to Mock:**
- Core Perl modules: `Time::HiRes`, `JSON::XS` — use real implementations
- Utility functions: `Purl::Util::Time::epoch_to_iso()` — test directly
- Password hashing: Real bcrypt library (Crypt::Bcrypt); not mocked
- Only mock I/O boundaries (external APIs, databases)

## Fixtures and Factories

**Test Data:**
- Inline constants: `is(epoch_to_iso(0), '1970-01-01T00:00:00Z', ...);`
- Temporary files: `File::Temp::tempfile()` for config file tests
- No factory libraries (Data::Faker, etc.); data created ad-hoc

**Example from `t/02_config.t`:**
```perl
my ($fh, $tmpfile) = tempfile(SUFFIX => '.json', UNLINK => 1);
print $fh '{"server":{"port":8080,"host":"1.2.3.4"}}';
close $fh;

local $ENV{PURL_CONFIG_FILE} = $tmpfile;
my $cfg = Purl::Config->new;
is($cfg->get('server', 'port'), 8080, 'JSON file overrides default port');
```

**Location:**
- Fixtures created inline in tests (no `t/fixtures/` directory)
- ENV variables set locally: `local $ENV{VAR} = $value;`
- Temporary files cleaned up automatically by `tempfile(UNLINK => 1)`

## Coverage

**Requirements:**
- No coverage threshold enforced
- No coverage reports generated
- Tools: None configured

**View Coverage:**
- Not available (no commands, no configuration)
- Pragmatic: Trust that tests exercise the code

## Test Types

**Unit Tests:**
- Scope: Individual functions and methods
- Approach: Call function with inputs, assert outputs
- Example: `t/01_time_util.t` tests `epoch_to_iso()` with various inputs
- No external dependencies (mocked or isolated)
- Fast execution

**Integration Tests:**
- Scope: Multiple modules working together
- Approach: Real ClickHouse queries, real HTTP calls to alerts
- Example: `t/14_controller_logs.t` tests full request-response cycle
- Some use MockStorage (no DB) for speed; some use real services
- Tests auth middleware + controller + rendering

**E2E Tests:**
- Framework: Playwright (TypeScript)
- Location: `.github/workflows/e2e.yml` and manual `make e2e-docker`, `make e2e-k8s`
- Scope: Browser automation of entire application
- Tests: Login flows, search, alerts, configuration changes
- Run: `make e2e-docker` or `make e2e-k8s` (requires Kind + Helm)

**Service/Smoke Tests:**
- Location: `tests/e2e/k8s-smoke.sh`, `tests/e2e/docker-compose-test.sh`
- Approach: Shell scripts checking service health
- Checks: HTTP 200 from /api/health, basic log ingest

## Common Patterns

**Async Testing:**
- Not directly applicable (Perl is synchronous)
- Controllers return immediately; render to JSON
- No promises/async/await in Perl tests

**Error Testing:**
```perl
subtest 'hash_password rejects short passwords' => sub {
    is $auth->hash_password('short'), undef, 'password < 8 chars rejected';
    is $auth->hash_password('1234567'), undef, '7 chars rejected';
    ok defined $auth->hash_password('12345678'), '8 chars accepted';
};
```

**Exception Testing:**
```perl
subtest 'verify_password legacy SHA256 migration' => sub {
    my $hash = $salt . '$' . Digest::SHA::sha256_hex($salt . 'legacypassword' . $salt);
    my ($valid, $new_hash) = $auth->verify_password('legacypassword', $legacy_hash);
    ok $valid, 'legacy SHA256 password verified';
    ok defined $new_hash, 'migration hash returned';
};
```

**State Verification:**
```perl
# In controller tests
my $ctrl = MockCtrl->new($body, $params, $headers, $stash);
$controller->login($ctrl);
is($ctrl->{session}{username}, 'admin', 'username set');
is($ctrl->{session}{role}, 'admin', 'role set');
```

## Test Execution

**Run all tests:**
```bash
make test
# Runs: PERL5LIB=lib prove -r t/ 2>/dev/null
```

**Run specific test file:**
```bash
PERL5LIB=lib prove -v t/01_time_util.t
```

**Run with verbose output:**
```bash
PERL5LIB=lib prove -v t/
```

**Integration with preflight:**
```bash
make preflight
# Runs: lint-perl → lint-js → test → web-build
# Stops on first failure
```

## Gaps and Notes

**Coverage gaps identified:**
- Frontend (Svelte) has no unit tests visible in codebase
- E2E tests exist (Playwright) but not integrated into `make test`
- No API contract/property-based testing
- ClickHouse queries not unit-tested in isolation (tested via integration tests)

**Why this works:**
- Perl code is mostly request handlers and utilities
- Logic complexity is low (data processing, config merging)
- External services (ClickHouse, alerts) tested by integration tests
- Frontend tested via E2E (faster than unit tests for interactive apps)

**Best practices observed:**
- Tests are co-located by module (time_util → 01_time_util.t)
- Each test file is self-contained (no shared test helpers)
- Mocks are minimal and purpose-built (no over-engineering)
- Test descriptions are clear and actionable
- Errors are explicit (not silent failures)

---

*Testing analysis: 2026-03-10*

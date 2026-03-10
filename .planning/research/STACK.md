# Stack Research

**Domain:** Quality hardening — Perl/Mojolicious + Svelte 5 log aggregation platform
**Researched:** 2026-03-10
**Confidence:** MEDIUM (all external search tools unavailable; based on codebase analysis + training knowledge through August 2025; verify versions before pinning)

---

## What This Research Covers

This is a subsequent-milestone research pass. The core stack (Perl 5.40, Mojolicious 9.x, Svelte 5, Vite 6, ClickHouse) is already decided and documented in `.planning/codebase/STACK.md`. This document covers only what is *missing* for quality hardening: testing libraries, coverage tools, static analysis, and refactoring utilities.

---

## Current State (from codebase analysis)

### What Exists

| Tool | Status | Location |
|------|--------|----------|
| `Test::More` | In use (all 40 test files) | `t/**/*.t` |
| `Test::Mojo` | In use (integration tests only) | `t/25_integration_flow.t` |
| `prove` | In use as test runner | `Makefile:test` |
| `Perl::Critic` (severity 4) | In use | `.perlcriticrc` |
| `ESLint 9.17` + `eslint-plugin-svelte 2.46` | In use | `web/eslint.config.js` |
| `Playwright 1.58` | In use (E2E, remote server only) | `web/e2e/*.spec.js` |
| `Devel::Cover` | **Not configured** | — |
| Vitest (Svelte unit tests) | **Not present** | — |
| `Test::Deep` | **Not present** | — |
| `Test::Exception` | **Not present** | — |

### Critical Gaps

1. **No coverage measurement** — 40 test files, ~9,945 lines of test code, but no way to know which production code is untested.
2. **Svelte components have zero unit tests** — Playwright only tests against a live remote server (`37.27.187.72:3000`).
3. **No structured exception testing** — exception paths tested with boolean checks; `Test::Exception` would make failures explicit.
4. **Hand-rolled mocks are inconsistent** — each test file defines its own `MockCtrl`/`MockReq`/`MockStorage` with subtly different interfaces.
5. **Playwright hardcodes remote IP** — E2E tests cannot run in CI without network access to production server.

---

## Recommended Stack for Quality Hardening

### Perl Testing — Core

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `Test::More` | bundled with perl 5.40 | Assertions (`ok`, `is`, `like`, `subtest`) | Already in use. TAP-native, no install needed. Do not replace. |
| `Test::Mojo` | bundled with Mojolicious 9.x | HTTP/WebSocket integration tests against real app | Already partially used. Standard Mojolicious test tool — chainable assertions over live request/response. Extend to all controllers. |
| `Test::Deep` | 1.204+ | Complex data structure assertions (`cmp_deeply`, `superhashof`, `bag`) | `is_deeply` from Test::More fails with unhelpful diffs; Test::Deep gives field-level mismatch. Use for JSON API response shape assertions. |
| `Test::Exception` | 0.43+ | Exception and die testing (`throws_ok`, `lives_ok`, `dies_ok`) | Current pattern `eval { ... }; ok($@, ...)` is fragile — it passes even if the wrong exception is thrown. Test::Exception makes error-path testing explicit. |

**Confidence:** MEDIUM — Test::Deep and Test::Exception are standard CPAN modules that have been stable for 10+ years. Version numbers from training data; verify on MetaCPAN before installing.

### Perl Testing — Coverage

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `Devel::Cover` | 1.40+ | Line, branch, condition, subroutine coverage | Standard Perl coverage tool. Produces HTML + text reports. Essential for identifying untested paths in 25+ controllers. |

**Usage:**
```bash
PERL5OPT=-MDevel::Cover PERL5LIB=lib prove -r t/
cover -report html          # Generates cover_db/coverage.html
cover -report text          # Quick terminal summary
```

**Why not alternatives:** `Devel::NYTProf` is a profiler, not a coverage tool — wrong tool for this purpose. `Devel::Cover` is the de-facto standard.

**Confidence:** HIGH — Devel::Cover is the only serious coverage tool in the Perl ecosystem.

### Perl Code Quality — Static Analysis

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `Perl::Critic` | already installed | Policy enforcement | Already in use at severity 4. For hardening, tighten to severity 3 for security-sensitive modules (`lib/Purl/API/Middleware/`, `lib/Purl/Alert/`). |
| `Perl::Tidy` | 20230309+ | Automatic code formatting | Perl has no `gofmt` or `prettier`. Perl::Tidy enforces consistent indentation, line length, brace style. Eliminates style debates in code review. |

**Perl::Tidy config (`.perltidyrc`):**
```
-l=100          # Max line length
-i=4            # 4-space indent
-ci=4           # Continuation indent
-vt=0           # Vertical tightness off (readable)
-pt=2           # Paren tightness
-sbt=2          # Square bracket tightness
-bt=2           # Brace tightness
-nsfs           # No space before semicolon
-nwls="="       # No space around = in hash args
```

**Confidence:** MEDIUM — Perl::Tidy is well-established but the `.perltidyrc` settings are preferences; adjust to project style.

### Perl Mocking

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Hand-rolled mocks (current pattern) | — | Mock Mojolicious controller/request/response | **Keep for controller unit tests.** The `MockCtrl`/`MockReq` pattern in use is appropriate for this codebase. The problem is inconsistency across files — extract to a shared `t/lib/TestHelper.pm`. |
| `Test::MockModule` | 0.177+ | Mock/override individual module methods | For cases where a full mock object is excessive — override one method on a real module (e.g., `Purl::Storage::ClickHouse::query`). More surgical than rewriting the whole module. |

**Why not `Test::MockObject`:** Heavyweight; the hand-rolled pattern already works well for this codebase.

**Shared test helper pattern (new file `t/lib/TestHelper.pm`):**
```perl
package TestHelper;

sub mock_controller {
    my (%args) = @_;
    return MockCtrl->new(
        $args{body}    // '{}',
        $args{params}  // {},
        $args{headers} // {},
        $args{stash}   // {},
    );
}

sub mock_storage { return Purl::Storage::InMemory->new }
```

**Confidence:** MEDIUM — `Test::MockModule` is a standard choice; hand-rolled mocks are sufficient if centralised.

### Svelte Frontend — Unit Testing

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `vitest` | 3.x | Unit/component test runner | Native Vite integration — shares the same vite.config.js, no separate build setup. Faster than Jest for Vite projects. The de-facto standard for Svelte 5 unit testing. |
| `@testing-library/svelte` | 5.x | Component rendering + DOM assertions | Renders Svelte 5 components in jsdom, provides `render()`, `fireEvent`, `screen`. Tests component behavior, not implementation details. Compatible with Svelte 5 runes. |
| `@vitest/coverage-v8` | 3.x | JS coverage via V8 | Built into V8 runtime, zero overhead. Use `--coverage` flag. Tracks branch/line coverage for stores and utility modules. |
| `jsdom` | 25.x | DOM environment for component tests | Required peer dependency for `@testing-library/svelte` in Node environment. |

**Why vitest over Jest:** Svelte 5 uses ES modules natively. Jest requires transform configuration to handle `.svelte` files and ESM; Vitest handles both natively because it runs inside Vite. Less config, faster cold starts.

**Why `@testing-library/svelte` over Svelte's own testing utilities:** Testing Library encourages testing behavior (what the user sees) rather than internals (reactive state, component instances). Svelte 5's rune-based reactivity makes internal state harder to test directly — Testing Library sidesteps this.

**Confidence:** MEDIUM — Vitest + @testing-library/svelte is the established community pattern for Svelte 5 as of mid-2025. Verify `@testing-library/svelte` v5 supports Svelte 5 runes before installing (v4 does not; v5 does).

**vitest.config.js (new file alongside vite.config.js):**
```javascript
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte({ hot: !process.env.VITEST })],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test-setup.js'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.{js,svelte}'],
      exclude: ['src/test-setup.js', 'src/**/*.spec.js'],
    },
  },
});
```

### Playwright E2E — Hardening

The current Playwright setup is functional but points at a hardcoded remote IP. For quality hardening:

| Issue | Current State | Fix |
|-------|--------------|-----|
| Remote server hardcoded | `baseURL: 'http://37.27.187.72:3000'` | Use `process.env.BASE_URL \|\| 'http://localhost:3000'` |
| No local server start | Tests fail if remote down | Add `webServer` config to start Docker Compose before tests |
| Playwright version | `^1.58.2` | Stay on 1.58.x — it works. Update only if a specific feature is needed. |

**Confidence:** HIGH — these are straightforward config improvements, not library changes.

---

## Installation

### Perl — add to cpanfile

```perl
# Testing (test-only dependencies)
on 'test' => sub {
    requires 'Test::Deep',       '1.204';
    requires 'Test::Exception',  '0.43';
    requires 'Test::MockModule', '0.177';
};

# Development only
on 'develop' => sub {
    requires 'Devel::Cover', '1.40';
    requires 'Perl::Tidy',   '20230309';
};
```

Install:
```bash
cpanm Test::Deep Test::Exception Test::MockModule
cpanm Devel::Cover Perl::Tidy
```

### Frontend — add to web/package.json devDependencies

```bash
cd web
npm install -D vitest @testing-library/svelte jsdom @vitest/coverage-v8
```

Add test script to `web/package.json`:
```json
"scripts": {
  "test": "vitest run",
  "test:watch": "vitest",
  "test:coverage": "vitest run --coverage"
}
```

### Makefile — new targets

```makefile
test-js:
	cd web && npm run test

test-coverage-perl:
	PERL5OPT=-MDevel::Cover PERL5LIB=lib prove -r t/ 2>/dev/null; cover -report text

coverage-html:
	PERL5OPT=-MDevel::Cover PERL5LIB=lib prove -r t/ 2>/dev/null; cover -report html
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `Test::Mojo` for integration | Real HTTP client (`HTTP::Tiny`) against localhost | Never for unit/integration tests — Test::Mojo runs in-process, no server start needed. HTTP::Tiny tests are for smoke tests against deployed environments. |
| `Devel::Cover` | `Devel::NYTProf` | NYTProf when you need profiling (CPU hotspots), not coverage. Different purpose. |
| `vitest` | `Jest` | Jest if the project already uses it elsewhere. For a Vite project starting fresh, vitest is always the better choice. |
| `@testing-library/svelte` | Direct Svelte component testing | Direct testing if testing rune reactivity internals specifically — but this is rarely the right goal for UI testing. |
| Hand-rolled mocks in shared helper | `Test::MockObject` | Test::MockObject if you have many varied mock types. For this codebase, a shared helper is simpler. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `Test::Unit` (Perl) | Heavyweight JUnit-style framework; mismatched paradigm for TAP-based Perl. Rarely seen in modern Perl. | `Test::More` + `subtest()` — already in use |
| `Moose` for test helpers | Excessive overhead for test-only classes | Plain `bless {}` or `Moo` |
| `Test2::Suite` as a replacement | Test2 is the future of Perl testing, but migrating 40 test files from Test::More mid-project adds risk with no tangible benefit. Test::More wraps Test2 internally already. | Keep `Test::More`; add Test2 only for new files if desired |
| `@playwright/test` for Svelte component tests | Playwright is E2E only — launching a browser to test a `<Button>` component is 100x slower than vitest + testing-library | `vitest` + `@testing-library/svelte` |
| `istanbul` / `nyc` for JS coverage | Legacy tooling; replaced by `@vitest/coverage-v8` in Vite projects | `@vitest/coverage-v8` |
| Increasing Perl::Critic to severity 1 globally | Will generate hundreds of violations in existing code, blocking CI. Correct approach is targeted severity increases per module. | Tighten severity in `.perlcriticrc` per-file using `## no critic` annotations or per-policy exclusion |

---

## Stack Patterns by Variant

**If adding tests for a new controller:**
- Write unit tests using hand-rolled mocks (follow pattern in `t/14_controller_logs.t`)
- Write integration tests using `Test::Mojo` (follow pattern in `t/25_integration_flow.t`)
- Both are needed: unit tests catch logic errors fast, integration tests catch routing/middleware bugs

**If adding tests for Svelte stores:**
- Use vitest directly (no component rendering needed)
- Import the store, call its functions, assert `get(store)` values
- Do not use `@testing-library/svelte` for pure store logic

**If adding tests for Svelte components:**
- Use `@testing-library/svelte` with `render()` + `screen` queries
- Test user-visible behavior (text on screen, button states), not Svelte internals

**If measuring coverage for the first time:**
- Run `Devel::Cover` once to identify the lowest-coverage modules
- Focus test writing efforts on critical paths first (auth middleware, ingest controller)
- Set a per-sprint coverage target (e.g., +10% each sprint), not an arbitrary global threshold

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| `@testing-library/svelte@5.x` | `svelte@5.x` | v4 does NOT work with Svelte 5 runes. Must be v5. |
| `vitest@3.x` | `vite@6.x` | vitest and vite should be on compatible major versions. v3 works with Vite 6. |
| `@vitest/coverage-v8` | `vitest@3.x` | Must match vitest major version. Install same version. |
| `eslint-plugin-svelte@2.46` | `svelte@5.16` | Already in use. No change needed. |
| `Test::Mojo` | `Mojolicious@9.x` | Bundled with Mojolicious — no separate install. Already available. |

---

## Sources

- Codebase analysis of `t/**/*.t` (40 files, 9,945 lines) — HIGH confidence for what exists
- Codebase analysis of `web/package.json`, `web/eslint.config.js`, `web/playwright.config.js` — HIGH confidence for current frontend tooling
- Training knowledge (through August 2025) for Perl CPAN module recommendations — MEDIUM confidence; verify versions on MetaCPAN
- Training knowledge for Vitest + @testing-library/svelte Svelte 5 compatibility — MEDIUM confidence; verify `@testing-library/svelte` v5 changelog before installing
- Note: WebSearch, WebFetch, and Bash tools were unavailable during this research session. All external version claims should be verified on MetaCPAN / npmjs.com before pinning.

---

*Stack research for: Perl/Mojolicious + Svelte 5 quality hardening*
*Researched: 2026-03-10*

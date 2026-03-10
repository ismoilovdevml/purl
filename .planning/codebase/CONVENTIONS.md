# Coding Conventions

**Analysis Date:** 2026-03-10

## Naming Patterns

**Files (Perl):**
- PascalCase with `::` separators for packages: `Purl::API::Controller::Logs.pm`
- Base classes: `Base.pm` in each category directory
- Provider/implementation pattern: `Role.pm` for Moo roles, concrete implementations in subdirectories
- Controllers: `lib/Purl/API/Controller/{ControllerName}.pm`
- Utilities: `lib/Purl/Util/{Utility}.pm`
- Middleware: `lib/Purl/API/Middleware/{MiddlewareName}.pm`

**Files (JavaScript/Svelte):**
- PascalCase for components: `Modal.svelte`, `SearchBar.svelte`, `SettingsPage.svelte`
- camelCase for stores: `auth.js`, `logs.js`, `license.js`
- camelCase for utilities: `dom.js`, `format.js`, `colors.js`
- kebab-case for directories: `components/ui/`, `components/settings/`, `components/dashboard/`

**Functions (Perl):**
- snake_case for subroutines: `hash_password()`, `verify_password()`, `parse_time_range()`, `epoch_to_iso()`
- Underscores for internal/private methods: `_generate_csrf_token()`, `_config()`, `_json()`
- Simple verbs or compound names: `search()`, `insert()`, `load()`, `safe_execute()`

**Functions (JavaScript):**
- camelCase: `checkAuth()`, `login()`, `logout()`, `changePassword()`
- Prefixed with handler verbs: `handleClick()`, `handleKeydown()`, `handleOverlayClick()`
- Async functions clearly labeled with `async`: `async function checkAuth()`

**Variables:**
- camelCase in both languages: `currentUser`, `sessionId`, `refreshInterval`, `errorMessage`
- Prefix underscore for private/internal: `_config`, `_http`, `_json`, `_transport`
- All-caps constants rarely used; defaults map uses `$DEFAULTS` hash

**Types (Perl/Moo):**
- Moo attributes: `has 'attribute_name' => (...)`
- Role names: `Purl::AI::Provider::Base` (Moo::Role)
- Packages use PascalCase: `MockCtrl`, `MockStorage`

**Types (Svelte):**
- JSDoc `@type` annotations for complex types: `@type {'sm' | 'md' | 'lg'}`
- Props exports: `export let variableName = default;`
- Component names: `export let size = 'md';`

## Code Style

**Formatting (Perl):**
- Tool: Manual (no auto-formatter configured)
- 4-space indentation
- Opening braces on same line: `if ($condition) {`
- Spacing around operators: `$a + $b`, `$key => $value`
- Line length: Generally kept under 120 characters (pragmatic, not strict)
- Comments on same line or above: `# Convert epoch to ISO8601`

**Formatting (JavaScript/Svelte):**
- Tool: ESLint (flat config in `web/eslint.config.js`)
- Settings:
  - `semi: ['error', 'always']` — Semicolons required
  - `quotes: ['warn', 'single', { avoidEscape: true }]` — Single quotes (unless escaping needed)
  - `'no-unused-vars': ['warn', { argsIgnorePattern: '^_' }]` — Underscore-prefixed params are intentionally unused
  - `'no-console': 'off'` — console.log allowed in development
- 2-space indentation in Svelte templates
- Opening braces on same line: `function toggle() {`

**Linting (Perl):**
- Tool: Perl::Critic
- Config: `.perlcriticrc` (severity 4, verbose output)
- Disabled checks (pragmatic overrides):
  - `ProhibitSubroutinePrototypes` — Allows prototypes for compatibility
  - `ProhibitInterpolationOfLiterals` — Allows string interpolation
  - `ProhibitPostfixControls` — Allows postfix if/unless
  - `ProhibitExcessComplexity` — High complexity allowed where warranted
  - `ProhibitExplicitReturnUndef` — Allows explicit `return undef`
  - `RequireFinalReturn` — Functions need not explicitly return
  - Many regex/control-flow checks relaxed for pragmatism

**Linting (JavaScript):**
- Tool: ESLint
- Config: `web/eslint.config.js`
- Base: `@eslint/js:recommended` + `eslint-plugin-svelte:flat/recommended`
- Browser + Node globals enabled
- ECMAVersion: 'latest'

## Import Organization

**Order (Perl modules):**
1. Pragmas: `use strict; use warnings; use 5.024;`
2. Core modules: `use Time::HiRes; use FindBin; use File::Spec;`
3. Third-party: `use Moo; use JSON::XS; use HTTP::Tiny;`
4. Local application: `use Purl::Config; use Purl::Storage::ClickHouse;`
5. Exporter declarations: `our @EXPORT_OK = qw(...);`
6. Special directives: `use namespace::clean;` (at end for Moo modules)

**Example from `Purl::Config`:**
```perl
use strict;
use warnings;
use 5.024;

use Moo;
use namespace::clean;
use JSON::XS ();
use File::Spec;
```

**Order (Svelte/JavaScript):**
1. Svelte imports: `import { onMount, onDestroy } from 'svelte';`
2. Third-party: `import { createEventDispatcher } from 'svelte';`
3. Local components: `import Modal from './Modal.svelte';`
4. Stores: `import { logs, loading } from './stores/logs.js';`
5. Utils: `import { trapFocus, lockScroll } from '../utils/dom.js';`

**Path Aliases:**
- Svelte: None configured; relative imports used (`./components/`, `../utils/`)
- Perl: PERL5LIB set to `lib/` in Makefile; packages use absolute paths via `use lib`

## Error Handling

**Patterns (Perl):**
- Try-eval-catch: `eval { ... }; if ($@) { ... }`
- Always check `$@` after eval
- `die` with descriptive messages for unrecoverable errors
- `warn` for non-fatal issues (logged to STDERR)
- Controllers use `safe_execute()` wrapper (in `Base.pm`):
  ```perl
  $self->safe_execute($c, sub {
      # ... code that might die ...
  });
  # Exceptions caught and rendered as JSON errors
  ```
- Explicit status codes: `render_error($c, $message, 400)` → 400, 403, 500 etc.
- Feature checks return early: `return $self->require_feature($c, 'feature_name')` → renders error + returns
- All API responses use JSON with `error` key on failure: `{ error: "message" }`

**Patterns (JavaScript/Svelte):**
- async/await with try-catch: `try { ... } catch { ... }`
- Always handle fetch failures: `if (!res.ok) throw new Error(...)`
- Auth errors stored in store: `currentUser.set(null)`
- UI errors displayed via toast: `toastWarning('Operation failed')`
- Functions that throw explicitly documented
- Stores have separate `authLoading`, `error` states
- Error state includes `retryFn` callback for user-initiated recovery

**Example from `auth.js`:**
```javascript
try {
  const res = await fetch(`${API_BASE}/auth/login`, {...});
  if (!res.ok) throw new Error(data.error || 'Login failed');
  currentUser.set({ username: data.username, role: data.role });
} catch {
  currentUser.set(null);
}
```

## Logging

**Framework (Perl):**
- Mojolicious built-in logger: `$c->app->log->warn()`, `$c->app->log->error()`
- Levels used: `warn` (non-fatal), `error` (500-level issues)
- Format: Application-controlled (Mojolicious default)
- No structured logging framework used

**Framework (JavaScript):**
- `console.log()`, `console.warn()`, `console.error()` (allowed by ESLint config)
- No logging library; direct console calls
- Errors also written to stores for UI display
- No log aggregation from frontend (frontend doesn't write to ClickHouse)

**Patterns:**
- Perl: Error in controller → `$c->app->log->error($message)` in `render_error()` (500s only)
- Perl: Warnings → `$c->app->log->warn()` in auth fallback scenarios
- JavaScript: Errors → `console.error()` + store update + UI toast
- No middleware-level request logging configured

## Comments

**When to Comment:**
- Inline comments above complex logic blocks (e.g., CSRF token generation)
- Section markers for logical grouping: `# ============================================`
- Constraint explanations: `# Token valid for 2 hours`
- Non-obvious regex: `# Remove Z suffix` above `$ts =~ s/Z$//;`
- Do NOT comment obvious code: `$x = $x + 1; # Increment x` ← avoid

**JSDoc/TSDoc:**
- Svelte components: HTML comment blocks above script
  ```svelte
  <!--
    Modal Component
    Reusable modal dialog with overlay

    Usage:
    <Modal bind:open title="Confirm">...</Modal>
  -->
  ```
- Svelte props: JSDoc `@type` for union types
  ```javascript
  /** @type {'sm' | 'md' | 'lg' | 'xl'} */
  export let size = 'md';
  ```
- Perl POD documentation: `=head1 NAME`, `=head1 SYNOPSIS`, `=cut`
- Example in `Purl::Config`:
  ```perl
  =head1 NAME
  Purl::Config - Configuration management with ENV > File > Default priority

  =head1 SYNOPSIS
  my $config = Purl::Config->new();
  my $host = $config->get('clickhouse', 'host');
  =cut
  ```

**Documentation style:**
- Perl modules: Full POD sections for public classes
- Private functions/methods: Comments above the sub
- Svelte: Usage examples in HTML comments; focus on prop types and slots

## Function Design

**Size (Perl):**
- Typical: 20–50 lines for controller handlers
- Complex logic split into separate methods
- Tests often define mock objects inline (MockCtrl, MockStorage) — accepted pattern

**Size (JavaScript):**
- Typical: 10–30 lines for component functions
- Async handlers: checkAuth, login, logout separated into distinct functions
- Store subscriptions: Separate `onMount` cleanup with `unsubscribe()`

**Parameters:**
- Perl: Positional arguments with named hash for optional: `sub method { my ($self, $arg1, %opts) = @_; }`
- Perl controllers: Always receive `$self` (object) and `$c` (Mojo controller context)
- JavaScript: Named parameters (destructuring), no positional after first arg
- Example: `async function checkAuth()` ← no params; uses global API_BASE constant

**Return Values:**
- Perl: Explicit return statements; undef for absence; arrays in list context
- Perl tests: Subroutines must return truthy for pass (or Test::More assertions)
- JavaScript: Explicit return or implicit undefined; async functions return Promise
- Example from `safe_execute`: `$cb->()` ← code ref called; result discarded; exceptions caught

## Module Design

**Exports (Perl):**
- Exporter used sparingly (mainly utilities): `our @EXPORT_OK = qw(epoch_to_iso parse_time_range ...);`
- Modules must be `use`d explicitly: `use Purl::Util::Time qw(epoch_to_iso);`
- Controllers/middleware use OOP (Moo) — no exports

**Exports (JavaScript):**
- Named exports: `export const currentUser = writable(null);`
- Default exports: Rare (mostly undefined)
- Barrel files: None used; direct imports
- Svelte components: Implicit export as default component

**Barrel Files:**
- Perl: No barrel/aggregator files; each module imported directly
- JavaScript: No barrel files; granular imports from individual files
- Rationale: Explicit dependencies, easier to tree-shake (JS), simpler mental model (Perl)

**Moo Patterns:**
- Attribute defaults use `default => sub { ... }` for lazy evaluation
- `lazy` flag for expensive initialization: `lazy => 1`
- `required => 1` for constructor-required attributes
- `is => 'ro'` (read-only) standard; `is => 'rw'` (read-write) for state-carrying objects
- `namespace::clean` at end of module to hide Moo internals

## Directory-by-Directory Style Rules

**`lib/Purl/API/Controller/`:**
- Extend `Purl::API::Controller::Base`
- Always receive context `$c` from Mojolicious
- Use `safe_execute()` wrapper for safety
- Return JSON: `$c->render(json => {...})`
- Status codes explicit: `status => 400`, `status => 403`

**`lib/Purl/API/Middleware/`:**
- Moo-based, composable middleware
- Methods called during request pipeline
- Return early on auth failure: `return 0;`
- Store results in `$c->stash()` for controllers to access

**`web/src/components/`:**
- Svelte single-file components (.svelte)
- Props documented in HTML comments
- Slots for content injection: `<svelte:fragment slot="footer">`
- CSS scoped by default (Svelte feature)
- Accessibility: `role="switch"`, `aria-checked`, `aria-label`

**`web/src/stores/`:**
- Svelte stores (writable, readable, derived)
- Async functions that call API and update store state
- Error handling in try-catch; errors propagated via throw
- No side effects in store initialization

---

*Convention analysis: 2026-03-10*

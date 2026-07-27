# Design: Purl Agent Org + Uncle-Bob Discipline Pipeline

- **Date**: 2026-07-27
- **Status**: Approved design — pending spec review
- **Author**: team lead (Claude) + user
- **Scope**: `.claude/agents/` for `purl` and `purl-web`, shared `~/.claude/agents/`, plus CLAUDE.md + memory updates

## 1. Problem

The Purl ecosystem has two repos but an unbalanced agent org:

- **purl** has 6 engineering agents (`backend-dev`, `frontend-dev`, `devops-engineer`,
  `qa-engineer`, `analytics-engineer`, `code-reviewer`) — good, but **engineering-heavy**:
  no product, design, market, or marketing roles, and no explicit "discipline pipeline".
- **purl-web** (Next.js 16 / TS / Supabase / Stripe SaaS) has **zero agents** — the biggest gap.

We also want to adopt Robert C. Martin's ("Uncle Bob") posture: *don't read every line the
agents write — build walls around them* (specs, tests, refactor pass, architecture check,
metrics) and trust the gate outputs. A disciplined multi-stage pipeline where **each stage is
stricter than the last and human line-reading is replaced by measured gates**.

## 2. Goals / Non-goals

**Goals**
- A complete, expert agent org across both repos: engineering + product + design + business + marketing.
- A disciplined pipeline: spec → code → refactor → architecture → review → QA gate.
- purl-web gets its own stack-specific engineering team.
- Discipline expressed as **agent prompts + orchestration** (light-touch). No new skills/hooks.

**Non-goals (this iteration)**
- No new enforcement tooling (coverage harness, mutation-testing framework, metrics dashboard).
  Walls are described in prompts and use existing tooling only.
- No changes to application code, CI, or deploy in this iteration — org/config only.
- No new issue tracker; purl stays on Claude memory, purl-web stays on `bd`/beads.

## 3. Architecture — 3 layers, 17 agents

### Layer A — purl engineering team (`purl/.claude/agents/`, existing 6, prompts refreshed)

`backend-dev`, `frontend-dev`, `devops-engineer`, `qa-engineer`, `analytics-engineer`, `code-reviewer`.

Refresh: each prompt gains a short "Pipeline & handoff" section pointing at the new stages
(receive Gherkin acceptance from `product-manager`; hand off to `refactoring-specialist` →
`architect-reviewer` → `code-reviewer` → `qa-engineer`). No domain/ownership changes.

### Layer B — purl-web engineering team (`purl-web/.claude/agents/`, NEW 5)

| Agent | Domain (paths) | Focus |
|---|---|---|
| `web-dev` | `src/app/**` (pages, route groups), `src/components/**`, `src/hooks/**` | Next.js 16 App Router, React 19 server/client components, Tailwind + shadcn/ui, landing/dashboard/admin UI |
| `platform-dev` | `src/app/api/**`, `src/lib/**` (stripe, license, email, rate-limit), `src/middleware.ts`, `vercel.json` | API routes, license JWT (generate/validate/verify-offline), Stripe checkout/webhook, Resend email, cron |
| `supabase-engineer` | `supabase/migrations/**`, `src/lib/supabase/**` | Schema, migrations, **RLS security** (launch blocker per audit), auth |
| `qa-web` | e2e/tests, `npm run lint`, `npm run build` | Lint + build + Playwright e2e, RLS policy tests, Stripe test-mode verification. Final gate for purl-web. |
| `code-reviewer-web` | `git diff` | TS/React conventions, RLS/authz gaps, Stripe webhook signature verification, secrets |

Rationale: purl-web deploys via **Vercel auto-deploy** on push — no dedicated devops agent
needed; `platform-dev` owns `vercel.json`/cron/env, `supabase-engineer` owns `supabase db push`.
Two focused reviewers (one per repo) beat one diluted cross-stack reviewer.

### Layer C — shared strategy + pipeline roles (`~/.claude/agents/`, NEW 6)

| Agent | Role | Pipeline stage |
|---|---|---|
| `product-manager` | Request → PRD + **Gherkin acceptance criteria** (Given/When/Then) + prioritization | Stage 1: spec |
| `ux-ui-designer` | User flows, UI design, design tokens (dark theme), accessibility — both dashboards | pre-code (UI work) |
| `business-analyst` | Market/competition (Loki, Datadog, Betterstack, SigNoz, Axiom, Graylog), pricing tiers, unit economics, conversion funnel | strategy |
| `marketing-strategist` | purlogs.com positioning, SEO, docs/blog content strategy, launch plan | strategy |
| `refactoring-specialist` | DRY, simplification, split oversized files — **writes** cleanup changes | Stage 3: refactor |
| `architect-reviewer` | Structure, SRP, boundaries, altitude + metrics report — **reads/judges** | Stage 4: architecture |

**Placement decision**: shared agents live in global `~/.claude/agents/` (single source of truth,
matches the "appears in both repos" intent). Trade-off: they are also visible in the user's other
projects (edcom, gitlab-ci-dashboard). Mitigation: prompts are **repo-adaptive** — each reads the
active project's `CLAUDE.md` and states its primary context is the Purl ecosystem (purl + purl-web).
If the user prefers strict isolation, the alternative is duplicating these 6 files into each repo's
`.claude/agents/` (2× files, sync burden). **Default: global + adaptive.**

## 4. Uncle-Bob discipline pipeline (orchestration)

Each stage stricter than the last; the team lead does **not** read every line — it reads the
**gate outputs** (metrics, verdicts) and trusts green gates.

```
1. product-manager    → PRD + Gherkin acceptance (Given/When/Then) + priority     [SPEC]
2. ux-ui-designer     → user-flow + design spec                     (only if UI change)
3. dev agents ‖       → TDD implement, satisfy the acceptance criteria             [CODE]
     purl:     backend-dev ‖ frontend-dev ‖ devops-engineer
     purl-web: web-dev ‖ platform-dev ‖ supabase-engineer
4. refactoring-spec   → DRY / simplify / split >400-line files (WRITES changes)    [REFACTOR]
5. architect-reviewer → SRP / boundaries / altitude + metrics report (READS)       [ARCHITECTURE]
6. code-reviewer(-web)→ correctness + security diff review (READS)
7. qa-engineer / qa-web → preflight gate + edge-case attack + acceptance verify    [GATE]
8. team lead          → commit / push  (ONLY if every gate is green)
```

Rules (carried from existing CLAUDE.md, extended):
- One domain = one owner; agents never edit each other's files; contracts pass through team lead.
- No agent runs `git push`; the team lead commits after the gate passes.
- If two agents must touch one file, run them sequentially, not in parallel.
- Strategy agents (`product-manager`, `business-analyst`, `marketing-strategist`) run for
  product/strategy work — not on every code change.

## 5. The "walls" (light-touch — described in prompts, existing tooling only)

- **Test wall**: `product-manager` writes Gherkin acceptance → dev agents satisfy via TDD →
  `qa` verifies each criterion. A behavior change without a test remains a FAIL (existing rule).
- **Metrics wall** (reported by `architect-reviewer` + `qa`, using existing tools):
  - File size: flag files > 400 lines as split candidates.
  - Duplication / blast radius: flag logic that already exists elsewhere; note what a change touches.
  - Coverage: run `make test` / `prove` / Playwright where a harness exists; report gaps.
- **Mutation testing**: no harness exists → treated as a **manual technique** the architect/QA may
  apply (deliberately inject a fault, confirm a test catches it), NOT a required gate. Stated
  honestly as aspirational.

## 6. Files changed by implementation

| File(s) | Change |
|---|---|
| `purl-web/.claude/agents/{web-dev,platform-dev,supabase-engineer,qa-web,code-reviewer-web}.md` | NEW — 5 agents |
| `~/.claude/agents/{product-manager,ux-ui-designer,business-analyst,marketing-strategist,refactoring-specialist,architect-reviewer}.md` | NEW — 6 shared agents |
| `purl/.claude/agents/*.md` (6) | Prompt refresh — add "Pipeline & handoff" section |
| `purl/CLAUDE.md` "Agent Jamoa" section | Rewrite roster + pipeline flow |
| `purl-web/CLAUDE.md` | Add new "Agent Jamoa" section (none today) |
| `~/.claude/projects/<slug>/memory/reference_agent_team.md` | Update org description |
| `docs/superpowers/specs/2026-07-27-agent-org-redesign-design.md` | This spec |

## 7. Agent prompt quality bar (every new agent)

Each agent file must be an **expert persona deeply immersed in its topic**, containing:
1. **Identity & domain** — who they are, exact path ownership, what they never touch.
2. **Mental models / what "great" looks like** in that domain (stack-specific idioms).
3. **Anti-patterns** they actively prevent.
4. **Reuse-first + tests-are-part-of-the-change** rules (mirrors existing purl agents).
5. **Pipeline & handoff** — where they sit in the pipeline, what they receive, what they hand off.
6. **Self-verification** — exact commands they run; never claim success without real output.
7. **Reporting format** — structured output back to the team lead. Never `git push`.

## 8. Acceptance criteria (Gherkin)

```gherkin
Feature: Purl agent org redesign

  Scenario: purl-web has a full engineering team
    Given the purl-web repo
    When I list purl-web/.claude/agents/
    Then I see web-dev, platform-dev, supabase-engineer, qa-web, code-reviewer-web

  Scenario: shared strategy + pipeline roles exist
    Given the global agents dir
    When I list ~/.claude/agents/
    Then I see product-manager, ux-ui-designer, business-analyst,
         marketing-strategist, refactoring-specialist, architect-reviewer

  Scenario: every agent file is valid
    Given any new or refreshed agent file
    Then it has YAML frontmatter with name + description
    And a body meeting the section 7 quality bar

  Scenario: orchestration documents the pipeline
    Given purl/CLAUDE.md and purl-web/CLAUDE.md
    Then each documents the spec -> code -> refactor -> architecture -> review -> QA pipeline
    And names which agents own which stage

  Scenario: memory reflects the new org
    Given reference_agent_team.md
    Then it lists all three layers and the pipeline flow
```

## 9. Risks & mitigations

- **Agent sprawl (17)** → clear layer/ownership table; strategy agents only for strategy work.
- **Global agents pollute other repos** → repo-adaptive prompts; user may switch to duplication.
- **Pipeline overhead for tiny changes** → orchestration notes the pipeline scales down (trivial
  fix may skip PM/UX/refactor and go straight code → review → QA).
- **Discipline is prompt-only, not enforced** → accepted trade-off this iteration; a later
  iteration can add hooks/skills (the "+ enforcement" option the user deferred).

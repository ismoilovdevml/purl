# Agent Instructions

Work state lives in **Claude memory** (`~/.claude/projects/<slug>/memory/`, loaded automatically each session) and `.planning/`. There is no separate issue tracker.

## Session Start

1. Memory loads automatically (SessionStart hook) — read the `MEMORY.md` index
2. `.planning/STATE.md` — current phase and progress
3. `git log --oneline -10` — what the last session did

## Landing the Plane (Session Completion)

**When ending a work session**, complete ALL steps. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **Run quality gates** (if code changed):

   ```bash
   make preflight   # lint-perl → lint-js → test → web-build, fail-fast
   ```

2. **PUSH TO REMOTE** — MANDATORY:

   ```bash
   git add <specific-files>
   git commit -m "type: description"
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```

3. **Update memory** — did any durable fact change? (server/config, project status, a blocker fixed, a new resource) → update the relevant memory file. The Stop hook prompts for this.
4. **Clean up** — clear stashes, prune remote branches
5. **Hand off** — leave context for the next session in memory, not just in chat

**CRITICAL RULES:**

- Work is NOT complete until `git push` succeeds
- NEVER push without `make preflight` passing. No `--no-verify`.
- NEVER stop before pushing — that leaves work stranded locally
- If push fails, resolve and retry until it succeeds

## Agent Team

Six specialized subagents live in `.claude/agents/`: `backend-dev`, `frontend-dev`, `devops-engineer`, `qa-engineer`, `analytics-engineer`, `code-reviewer`. The main session acts as team lead — splits the task, runs agents in parallel, merges results. See the "Agent Jamoa" section in CLAUDE.md for orchestration rules.

## Code Quality — binding for every agent

- **Reuse first**: before writing any helper/component, search `lib/Purl/Util/`, `Controller/Base.pm`, `web/src/components/ui/`, `stores/`, `utils/`. The same logic in 2+ places is a defect — extract it to the right module.
- **Tests ship with the change**: backend → `t/`, frontend flows → `web/e2e/`. A bugfix includes a regression test that fails without the fix. No test = the change is not done.
- **Structure is sacred**: one file = one job (400+ lines → split); code goes in its designated directory, never the "nearest convenient" file.

## Dev Environment

Dev deploys target the **dev k8s cluster** (namespace `purl-dev`), not a standalone server — see the Deployment section in CLAUDE.md.

# Purl — Lightweight Log Aggregation System

## Project Overview
Self-hosted log aggregation platform. Backend: Perl 5.24+ / Mojolicious. Frontend: Svelte 5 / Vite. Storage: ClickHouse. Deployment: Docker.

## Tech Stack
- **Backend**: Perl 5.40, Mojolicious, Moo OOP, ClickHouse HTTP API
- **Frontend**: Svelte 5, Vite, vanilla CSS (dark theme)
- **Storage**: ClickHouse (time-series logs, patterns, alerts)
- **Auth**: API keys (ingest), session cookies (dashboard), JWT RS256 (license)
- **Alerts**: Telegram, Slack, Webhook
- **CI/CD**: GitHub Actions → Docker Hub (`ismoilovdev/purl`)
- **Docker tags**: `main` → `:latest`, `dev` → `:dev`

## Key Commands
```bash
make up              # Start Purl + ClickHouse
make down            # Stop services
make lint            # Perl::Critic + ESLint
make web-dev         # Frontend dev server (Vite HMR)
make web-build       # Build frontend assets
make test            # Run Perl tests
make clickhouse-client  # ClickHouse shell
docker compose up -d    # Direct Docker
```

## Directory Structure
```
lib/Purl/
├── API/Server.pm              # Mojolicious app, routes, middleware
├── API/Controller/*.pm        # 13 controllers (Logs, Alerts, Patterns, Auth, etc.)
├── API/Middleware/Auth.pm      # API key & session auth
├── API/Middleware/License.pm   # JWT license verification
├── Storage/ClickHouse/*.pm    # 6 storage modules (Query, Cache, Alerts, Patterns, etc.)
├── Alert/*.pm                 # Telegram, Slack, Webhook
├── Config.pm                  # ENV-based configuration
└── Util/Time.pm               # Time range parser
web/src/
├── App.svelte                 # Root component
├── components/settings/       # Settings pages (License, Users, Database, etc.)
├── stores/                    # auth.js, logs.js, license.js, settings.js
└── utils/                     # format.js, colors.js, dom.js
```

## Code Conventions
- Perl: `use strict; use warnings; use 5.024;` — Moo for OOP, `namespace::clean`
- Controllers extend `Purl::API::Controller::Base` (provides safe_execute, render_error, caching)
- Feature gating: `$self->require_feature($c, 'feature_name')` checks license JWT
- JSON responses: `$c->render(json => { ... })` or manual JSON for BigInt-safe strings
- Svelte: stores in `web/src/stores/`, UI components in `web/src/components/ui/`
- Perl::Critic config: `.perlcriticrc`
- ESLint config: `web/eslint.config.js`

## Environment Variables (.env.example)
- `PURL_PORT`, `PURL_HOST` — Server config
- `PURL_CLICKHOUSE_*` — Database connection
- `PURL_API_KEYS` — Comma-separated ingest API keys
- `PURL_RETENTION_DAYS` — Log TTL
- `PURL_TELEGRAM_*`, `PURL_SLACK_*`, `PURL_ALERT_WEBHOOK_*` — Alert channels

## Deployment
- **Production server**: `172.17.4.16:3000` (Docker Compose, Enterprise license)
- **Docker image**: `ismoilovdev/purl:latest` (prod), `ismoilovdev/purl:dev` (dev)
- **Config volume**: `./config:/app/config:ro` (settings.json, users, license)

## Related Project
- **purl-web** (SaaS marketing/dashboard): `/Users/macbook/Documents/devops/personal/purl-web`
  - Next.js 16, Supabase, Stripe, Vercel
  - Generates license keys for purl instances
  - See its own CLAUDE.md for details

## Issue Tracking (bd / beads)

This project uses `bd` for issue tracking. **ALWAYS** follow this workflow:

### Session Start — MANDATORY EVERY TIME

Before doing ANY work, run these commands to understand the current state:

```bash
bd list --status=closed --limit=10  # FIRST: recent history — what was done before?
bd list --status=in_progress        # Is there work already claimed?
bd ready                            # What's ready to work on (no blockers)?
bd list --status=open               # All open issues
bd stats                            # Project health overview
```

**Why history first?** New sessions lose context. Reading recent closed issues tells you what was just completed, what decisions were made, and what the current state of the project is. Never start work without checking this.

### During Work

```bash
bd create --title="..." --type=task|bug|feature --priority=2  # Create issue
bd update <id> --status=in_progress   # Claim work BEFORE starting
bd show <id>                          # View issue details
bd dep add <issue> <depends-on>       # Add dependency
```

### Session End — MANDATORY CHECKLIST

```bash
bd close <id> --reason="..."    # Close completed issues (with context for next session)
bd sync --from-main             # Sync beads with main
git add . && git commit -m "..." && git push
```

**Rules**:

- **ALWAYS** run `bd list --status=closed --limit=10` FIRST — history is your memory
- Check `bd ready` before picking any task
- Create `bd` issues for any multi-step or cross-session work
- Close issues immediately when done — include meaningful `--reason` for next session context
- Priority: 0=critical, 1=high, 2=medium, 3=low, 4=backlog

## Credentials

**ALL credentials are in `CREDENTIALS.md`** (git-ignored, never commit). This file contains:
- Production server credentials (172.17.4.16 SSH, .env values)
- Supabase project refs, anon keys, service role keys (prod + dev)
- Stripe API keys (test mode), webhook secrets, product/price IDs
- Docker Hub credentials
- RSA keypairs for license JWT signing
- purl-web Vercel project info

**Read `CREDENTIALS.md` FIRST** whenever you need any API key, token, password, or service credential. Do not guess or ask — it's all documented there.

Quick reference for fresh env vars:
```bash
# purl-web: pull all Vercel env vars
cd /Users/macbook/Documents/devops/personal/purl-web && vercel env pull .env.local
```

## Git Workflow

- `main` = production, `dev` = development
- Push to `main` → CI builds Docker `:latest` + SHA tag
- Push to `dev` → CI builds Docker `:dev` + SHA tag
- PRs: lint + build test only (no push)

**ALWAYS set local git identity before committing** (do NOT use global git config):

```bash
git config --global --unset user.name  2>/dev/null || true
git config --global --unset user.email 2>/dev/null || true
git config --local user.name  "ismoilovdevml"
git config --local user.email "ismoilovdevarchlinux@gmail.com"
```

## Claude Agent Best Practices (Max 20x)

### Context Window — Asosiy Muammo va Yechim

Context to'lib qolishi eng katta failure mode. Qoidalar:

- **Har yangi vazifada `/clear`** — eski tarix tokenlarni ifloslantiradi
- **`/compact`** — context 70%+ bo'lganda, muhim kontekst yo'qolishidan oldin
- **Context 50% dan oshmasin** — 80% da indicator chiqsa allaqachon kech
- **Katta fayllarni to'liq o'qitma** — kerakli qismga yo'naltir (`offset` + `limit`)
- **Subagentlar** — tadqiqot va izlash uchun Task tool ishlatish (asosiy contextni ifloslantirmaydi)

### Subagentlar — Parallel Ishning Asosi

Har bir subagent o'z izolyatsiya qilingan context window-ida ishlaydi:

```
# Parallel ishga tushirish — bir xabar ichida bir nechta Task tool call:
Task(Explore): "lib/Purl/API/ ni tahlil qil"     → o'z context-ida
Task(Bash):    "make lint chiqishini tekshir"      → o'z context-ida
Task(Plan):    "feature X implementatsiya rejasi"  → o'z context-ida
```

Subagent turlar:
- `Explore` — faqat o'qish, codebase izlash (Glob, Grep, Read)
- `Plan` — arxitektura va implementatsiya rejasi
- `Bash` — git, npm, docker, terminal operatsiyalari
- `general-purpose` — murakkab ko'p bosqichli vazifalar

### Git Worktree — 5-10 Agent Parallel

Bir vaqtda bir nechta feature ishlab chiqish uchun:

```bash
# Har feature uchun alohida worktree
git worktree add ../purl-auth    -b feature/auth
git worktree add ../purl-api     -b feature/new-api
git worktree add ../purl-tests   -b feature/tests

# Tugatgach tozalash
git worktree remove ../purl-auth
```

Har bir worktree-da alohida Claude Code sessiyasi — parallel, izolyatsiya qilingan.

### CLAUDE.md Yozish Qoidalari

- **Qisqa saqlang**: 150-300 qator maksimum. LLM qancha ko'p o'qisa shuncha yaxshi emas
- **"Qayerdan topish" ko'rsatish**: "CREDENTIALS.md da API kalitlar bor" — narsani o'zini emas
- **Faqat xato qiladigan narsalar**: standart Perl/Svelte qoidalari emas, loyiha-spesifik narsalar
- **Subfolder CLAUDE.md**: `lib/CLAUDE.md`, `web/CLAUDE.md` — katta loyihalarda ajratish
- **Har sessiya boshida bd**: context yo'qolishi muammosini hal qiladi

### Invocation Best Practices

Subagentga vazifa topshirganda:
1. **Aniq maqsad**: nima qilishi, nima qaytarishi
2. **Fayl yo'llari**: qaysi fayllarga qarashi kerak
3. **Muvaffaqiyat mezoni**: nima bo'lganda tugatadi
4. **Yozish yoki faqat o'qish**: ikkalasini aralashtirma

# Purl — Lightweight Log Aggregation System

## Project Overview

Self-hosted log aggregation platform. Backend: Perl 5.40 / Mojolicious. Frontend: Svelte 5 / Vite. Storage: ClickHouse. Deployment: Docker.

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
make lint            # Perl::Critic + ESLint (both)
make lint-perl       # Perl syntax + Perl::Critic only
make lint-js         # ESLint only
make test            # Run Perl tests (prove -r t/)
make web-build       # Build frontend assets
make web-dev         # Frontend dev server (Vite HMR)
make preflight       # FULL verification: lint + test + build (run before push)
make clickhouse-client
```

## Pre-Push Gate — MANDATORY

**NEVER push without running `make preflight`.** This runs lint + test + build sequentially and fails fast on any error.

```bash
# Before ANY git push:
make preflight       # Runs: lint-perl → lint-js → test → web-build
```

If preflight fails, fix ALL errors before pushing. No exceptions. No `--no-verify`. CI runs the same checks — failing locally saves time.

When using subagents, run verification in parallel:

```text
Task(Bash): "make lint-perl"   # Parallel
Task(Bash): "make lint-js"     # Parallel
Task(Bash): "make test"        # Parallel
# Wait for all three, then:
Task(Bash): "make web-build"   # After lint passes
```

## Directory Structure

```text
lib/Purl/
├── API/Server.pm              # Mojolicious app, routes, middleware
├── API/Controller/*.pm        # Controllers (Logs, Alerts, Patterns, Auth, etc.)
├── API/Middleware/Auth.pm      # API key & session auth
├── API/Middleware/License.pm   # JWT license verification
├── Storage/ClickHouse/*.pm    # Storage modules (Query, Cache, Alerts, Patterns, etc.)
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
- Perl::Critic config: `.perlcriticrc` | ESLint config: `web/eslint.config.js`

## Environment Variables (.env.example)

- `PURL_PORT`, `PURL_HOST` — Server config
- `PURL_CLICKHOUSE_*` — Database connection
- `PURL_API_KEYS` — Comma-separated ingest API keys
- `PURL_RETENTION_DAYS` — Log TTL
- `PURL_TELEGRAM_*`, `PURL_SLACK_*`, `PURL_ALERT_WEBHOOK_*` — Alert channels

## Deployment

### Environments

Canonical infra map lives in local memory: `reference_infra_map.md` (auto-recalled each session). Summary:

| Environment         | Where                                 | Purpose                                                  |
|---------------------|---------------------------------------|----------------------------------------------------------|
| **Dev k8s cluster** | master-01 `5.189.148.112` (see below) | PRIMARY dev — ns `purl-dev` <http://5.189.148.112:30300> |
| Demo/Test (LEGACY)  | `37.27.187.72:3000` (Rocky Linux 9.7) | Manual only — CI deploy removed 2026-07-14               |
| Internal "prod"     | `172.17.4.16:3000`                    | Private-IP host from CREDENTIALS.md — status unverified  |

Dev k8s cluster nodes (SSH `root@<ip>`, port 22): master-01 `5.189.148.112` (kubectl/helm), worker-01 `5.189.145.83`, worker-02 `5.189.182.131`.

### Dev Deploy (k8s)

Push to `dev` branch → GitHub Actions builds `ismoilovdev/purl:dev` → CI SSHes to master-01 and runs `helm upgrade --install purl -n purl-dev -f values-dev.yaml -f /opt/purl-dev/values-secrets.yaml` → rollout status + health check.

Manual update (if CI is down):

```bash
ssh root@5.189.148.112 'helm upgrade --install purl /opt/purl-dev/chart -n purl-dev \
  -f /opt/purl-dev/chart/values-dev.yaml -f /opt/purl-dev/values-secrets.yaml'
ssh root@5.189.148.112 'kubectl -n purl-dev get pods && curl -s http://localhost:30300/api/health'
```

Rollback: `ssh root@5.189.148.112 'helm -n purl-dev rollback purl <rev>'`

### Helm Chart Publishing

Public chart repo: `https://charts.purlogs.com` (Vercel static project `purl-charts`) — this is what the website docs' `helm repo add purl https://charts.purlogs.com` points to. After chart changes: bump `chart/Chart.yaml` version, then `make chart-publish`.

### Docker

- **Image**: `ismoilovdev/purl:${PURL_IMAGE_TAG:-latest}` (env var controls tag)
- **Server tag**: `PURL_IMAGE_TAG=dev` (set in server `.env`)
- **Config volume**: `./config:/app/config` (settings.json, users, license)
- **Credentials**: `/opt/purl/.credentials` (auto-generated by install script)

## Related Project

- **purl-web** (SaaS marketing/dashboard): `/Users/macbook/Documents/devops/personal/purl-web`
  - Next.js 16, Supabase, Stripe, Vercel — see its own CLAUDE.md

## Credentials

**ALL credentials are in `CREDENTIALS.md`** (git-ignored, never commit). Read it FIRST for any API key, token, password, or service credential. Do not guess or ask.

## Git Workflow

- `main` = production, `dev` = development
- Push `main` → Docker `:latest` + SHA tag | Push `dev` → Docker `:dev` + SHA tag

**Git identity** (set before first commit):

```bash
git config --local user.name  "ismoilovdevml"
git config --local user.email "ismoilovdevarchlinux@gmail.com"
```

**Push checklist** (har doim shu tartibda):

```bash
make preflight                    # 1. FULL verification (lint + test + build)
git add <specific-files>          # 2. Stage only relevant files
git commit -m "type: description" # 3. Commit
git push                          # 4. Push ONLY after preflight passes
```

## Ish Kuzatuvi va Xotira (Claude Memory)

Issue tracker yo'q. Ish holati **Claude memory** (lokal, `~/.claude/projects/<slug>/memory/`) va `.planning/` da saqlanadi. Memory hooklar avtomatik ishlaydi: SessionStart (yuklash), UserPromptSubmit (recall), Stop (yangilash).

### Session Start — HAR DOIM

1. Memory avtomatik yuklanadi (hook) — `MEMORY.md` indeksini va tegishli faktlarni o'qi
2. `.planning/STATE.md` — joriy faza va progress
3. `git log --oneline -10` — oldingi sessiyada nima qilindi

### Session End — MAJBURIY

```bash
make preflight                       # 1. Lint + Test + Build MUST pass
git add <aniq-fayllar>               # 2. Faqat tegishli fayllar
git commit -m "type: tavsif"         # 3. Commit
git push                             # 4. Faqat preflight yashil bo'lsa
```

Keyin: **durable fakt o'zgardimi?** (server/config/loyiha holati/tuzatilgan bloker/yangi resurs) → tegishli memory faylni yangila. Stop hook buni eslatadi.

### Ishni Rejalashtirish — Senior Level Qoidalar

**Katta tasklarni DOIM bo'l.** Bitta ish birligi 1-2 soatlik bo'lsin; undan katta bo'lsa — bo'l.

- Katta ish (3+ soat) → TodoWrite bilan subtasklarga bo'l, agentlarga taqsimla
- Har ish uchun 4 narsa aniq bo'lsin: **muammo** (hozir nima bo'lyapti), **dizayn** (qaysi fayllar, qanday yondashuv), **acceptance** (nimani tekshirib "tayyor" deymiz), **egasi** (qaysi agent)
- Bitta sessiyada bitta yo'nalish — parallel agentlar bo'lsa ham, mavzu bitta bo'lsin
- Ish tugagach memory'ga yoz: nima qilindi, nega — keyingi sessiya bilsin

**Uzoq muddatli reja**: `.planning/ROADMAP.md` (fazalar) + `.planning/STATE.md` (joriy holat). Production blokerlari memory'da: `project_production_readiness_audit.md` (purl) va `project_purlweb_audit.md` (purl-web).

### Kod Yozish — Senior Level Printsiplar

**Bitta faylga ko'p narsa yozma.** Single Responsibility — har fayl bitta vazifa.

- Controller: faqat request/response. Biznes logika Storage yoki alohida modulda
- 200+ qatorlik fayl → bo'lish kerakmi deb o'yla. 400+ → albatta bo'l
- Yangi feature = yangi fayl. Mavjud faylga "yana bitta method" qo'shma
- Helper/util faqat 2+ joyda ishlatilsa yaratilsin. 1 joyda — inline yoz

**Reuse first — kod yozishdan OLDIN mavjudini qidir.**

- Perl: `Util/*`, `Controller/Base.pm`, `Storage/ClickHouse/*` da bormi — grep qil, keyin yoz
- Svelte: `components/ui/`, `stores/`, `utils/` da bormi — tekshir, keyin yoz
- Bir xil logika 2+ joyda = defekt. To'g'ri modulga chiqar, ikkala chaqiruvchini unga o'tkaz
- Strukturani buzma: kod o'z papkasiga — "eng yaqin faylga" tiqib qo'yish taqiqlanadi

**Test — o'zgartirishning bir qismi, keyinga qoldirilmaydi.**

- Har behavior o'zgarishi test bilan keladi: backend → `t/`, frontend flow → `web/e2e/`
- Bugfix → fixsiz FAIL bo'ladigan regression test
- Testsiz o'zgarish = qa-engineer uchun FAIL, code-reviewer uchun MAJOR/BLOCKER

**Fayl bo'lish misollari:**

```text
# YOMON: bitta katta controller
lib/Purl/API/Controller/Admin.pm  (500+ qator, users + settings + license)

# YAXSHI: alohida controllerlar
lib/Purl/API/Controller/Users.pm
lib/Purl/API/Controller/Settings.pm
lib/Purl/API/Controller/License.pm
```

**Commit granularity:** Bitta commit = bitta mantiqiy o'zgartirish. "Fix everything" commit yo'q.

## Agent Jamoa (.claude/agents/) — ISHNI SHU JAMOA QILADI

Loyihada 6 ta ixtisoslashgan subagent bor. User "shu ishni qilish kerak" deganda asosiy sessiya **team lead** bo'ladi: vazifani bo'ladi, tegishli agentlarni PARALLEL ishga tushiradi, natijalarni birlashtiradi.

| Agent                | Hudud                                             | Qachon                                                  |
|----------------------|---------------------------------------------------|---------------------------------------------------------|
| `backend-dev`        | `lib/Purl/**`, `t/`, cpanfile                     | Perl/Mojolicious/ClickHouse storage o'zgarishi          |
| `frontend-dev`       | `web/**`                                          | Svelte komponent/store/UI o'zgarishi                    |
| `devops-engineer`    | Dockerfile, compose, `.github/`, chart/, deploy/  | Infra, CI/CD, server, Helm                              |
| `qa-engineer`        | `t/`, `web/e2e/`, make gates                      | Har qanday ish tugagach verifikatsiya (preflight gate)  |
| `analytics-engineer` | ClickHouse SQL, metrics, biznes-analitika         | Query perf, product metrics, tarif/raqobat tahlili      |
| `code-reviewer`      | git diff                                          | Commit oldidan review                                   |

**Standart oqim** (feature/bugfix):

```text
1. Team lead vazifani bo'ladi (katta ish → TodoWrite bilan subtasklarga)
2. Task(backend-dev) ‖ Task(frontend-dev) ‖ Task(devops-engineer) — parallel, har biri o'z hududida
   (agentlar bir-birining fayliga tegmaydi; API kontraktni team lead kelishtirib ikkalasiga beradi)
3. Task(qa-engineer) — make preflight + edge-case hujum. FAIL → topilma egasiga qaytadi (2-qadam)
4. Task(code-reviewer) — diff review. BLOCKER → egasiga qaytadi
5. Team lead: commit → push (faqat preflight yashil bo'lsa)
```

Qoidalar: bitta hudud = bitta egasi (fayl to'qnashuvi yo'q); agentlararo xabar team lead orqali; hech bir agent git push qilmaydi; agar ikkala agent bir faylga tegishi kerak bo'lsa — ketma-ket, parallel emas.

## Multi-Agent Workflow — ASOSIY QOIDA

**Har doim subagentlarni parallel ishga tushir.** Asosiy context window ni toza saqlash uchun tadqiqot va verifikatsiyani subagentlarga topshir.

### Pattern 1: Tadqiqot (Explore parallel)

Yangi sessiya yoki katta feature boshlaganda:

```text
Task(Explore): "lib/Purl/API/Controller/ — barcha controllerlarni tahlil qil, patterns top"
Task(Explore): "web/src/ — Svelte komponentlar arxitekturasini tahlil qil"
Task(Explore): "t/ — mavjud testlarni o'qib, qanday test pattern ishlatilganini ayt"
```

### Pattern 2: Implementatsiya + Verifikatsiya

Kod yozganingdan keyin — parallel tekshir:

```text
Task(Bash): "cd /Users/macbook/Documents/devops/personal/purl && make lint-perl"
Task(Bash): "cd /Users/macbook/Documents/devops/personal/purl && make lint-js"
Task(Bash): "cd /Users/macbook/Documents/devops/personal/purl && make test"
```

Hammasi o'tsa → `make web-build` → commit.

### Pattern 3: Katta feature — Plan + Parallel Build

```text
Task(Plan): "Feature X ni qanday implement qilish — lib/ va web/ arxitekturaga mos"
# Plan tasdiqlangach:
Task(Bash): "Perl backend o'zgartirish — lint-perl bilan tekshir"
Task(Bash): "Svelte frontend o'zgartirish — lint-js bilan tekshir"
# Ikkalasi tugagach:
Task(Bash): "make preflight"  # Final verification
```

### Pattern 4: Bug fix — Tez tsikl

```text
Task(Explore): "Bug ni toping — <xato tavsifi>, qaysi faylda ekanini aniqlang"
# Natija asosida fix yoz, keyin:
Task(Bash): "make preflight"  # Tekshir va tamom
```

### Subagent turlari

| Tur | Ishlatish | Misol |
| --- | --------- | ----- |
| `Explore` | Faqat o'qish, codebase izlash | "Bu error qayerdan kelyapti?" |
| `Plan` | Arxitektura, implementatsiya rejasi | "RBAC ni qanday qo'shish kerak?" |
| `Bash` | Terminal: lint, test, build, git | "make lint-perl natijasini ko'rsat" |
| `general-purpose` | Murakkab ko'p bosqichli | "Bu API ni refactor qil va test yoz" |

### Context Window Qoidalari

- **`/clear`** har yangi vazifada — eski tokenlarni tozala
- **`/compact`** context 60%+ bo'lganda
- **Katta fayllarni to'liq o'qitma** — `offset` + `limit` ishlatish
- **Subagentlarni ishlat** — asosiy context ni toza saqla
- Bitta xabarda bir nechta Tool call — parallel ishlaydi, tezroq

### Git Worktree — Ko'p Agent Parallel

```bash
git worktree add ../purl-feature-x -b feature/x
git worktree add ../purl-fix-y     -b fix/y
# Har birida alohida Claude Code sessiyasi
git worktree remove ../purl-feature-x  # Tugatgach tozala
```

### Invocation Qoidalari

Subagentga vazifa berganda 4 ta narsa majburiy:

1. **Aniq maqsad** — nima qilishi va nima qaytarishi
2. **Fayl yo'llari** — qaysi fayllar bilan ishlashi
3. **Muvaffaqiyat mezoni** — qachon "tayyor" deyish mumkin
4. **Yozish/O'qish** — faqat birini berish, aralashtirmaslik

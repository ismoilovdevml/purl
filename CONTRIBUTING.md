# Contributing to Purl

Thanks for taking the time to help. Bug reports, fixes, docs and features are
all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on
  the approach before you write the code.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Development setup

You need Docker (with Compose), Perl 5.42, Node.js 24 and `make`. Helm is
only needed if you touch `chart/`.

```bash
git clone https://github.com/ismoilovdevml/purl.git
cd purl
cp .env.example .env        # then set PURL_CLICKHOUSE_PASSWORD and PURL_API_KEYS

make up                     # Purl + ClickHouse via Docker Compose, on :3000
make web-dev                # Vite dev server with hot reload, proxies /api to :3000
```

`make up` runs the published `ismoilovdev/purl` image. To run your own backend
changes in the stack, build the image and point Compose at it:

```bash
docker build -t ismoilovdev/purl:local .
PURL_IMAGE_TAG=local make up
```

Perl dependencies for linting and tests are installed into `~/perl5`, the same
layout CI uses:

```bash
cpanm --local-lib ~/perl5 --installdeps .
cpanm --local-lib ~/perl5 Perl::Critic Test::More File::Temp Test::MockModule
```

## Checks

Run this before every pull request. CI runs the same checks.

```bash
make preflight              # Perl lint + ESLint + Perl tests + frontend build
```

Individual targets: `make lint-perl`, `make lint-js`, `make test`,
`make web-build`, and `make helm-lint` for chart changes. Browser tests live in
`web/e2e/` and run with `cd web && npm run test:e2e`.

A change in behaviour should come with a test: backend tests go in `t/`,
frontend flows in `web/e2e/`. A bug fix should include a test that fails
without the fix.

## Branches and pull requests

- `main` is the released code. `dev` is where work lands.
- Branch off `dev` and open your pull request against `dev`.
- Keep a pull request to one logical change. Several small PRs are easier to
  review than one large one.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/), with an
optional scope:

```text
fix(live-tail): deliver tailed logs across prefork workers
feat(auth): accept a bearer token on ingest routes
docs,ci: point the Kubernetes docs at the chart
```

Common types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`. Say
what changed and, where it is not obvious, why.

## Code style

- Perl: `use strict; use warnings;`, Moo for classes. `.perlcriticrc` is the
  source of truth.
- Frontend: Svelte 5, plain CSS. `web/eslint.config.js` is the source of truth.
- Configuration is read from environment variables. If you add one, document
  it in `.env.example`.

## License

By contributing you agree that your contributions are licensed under the
[MIT license](LICENSE).

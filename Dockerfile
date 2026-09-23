# Base images are pinned by DIGEST, not just by tag. A tag is mutable: the
# same `docker build` a week later can produce a different image than the one
# Trivy scanned and cosign signed in CI. Refresh with:
#   docker buildx imagetools inspect <image>:<tag>   # copy the index Digest
# and bump the tag comment alongside it.

# Build web assets — node:24-alpine (Active LTS). Node 20 is EOL; 26 is not
# picked while it is still "Current" (not LTS). Vite 8 / ESLint 10 need
# ^20.19 || >=22.12, so any 22+/24 LTS satisfies them.
FROM node@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1 AS web-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# Perl dependencies builder (build-essential only here, not in final image)
# Stable Perl releases only: an ODD minor (5.41, 5.43, ...) is a development
# series and must never be a base image (see .github/dependabot.yml ignore).
# perl:5.42-slim-bookworm
FROM perl@sha256:cb30febd1c9b2bc88c77047454ca0eb8cd0defefad8312bcf3957e6e25e05711 AS perl-builder

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    build-essential libssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://cpanmin.us | perl - App::cpanminus

ENV TAR_OPTIONS="--warning=no-unknown-keyword"

WORKDIR /app
COPY cpanfile ./
RUN cpanm --notest --installdeps .

# Final image (no build-essential = ~400MB smaller)
# perl:5.42-slim-bookworm
FROM perl@sha256:cb30febd1c9b2bc88c77047454ca0eb8cd0defefad8312bcf3957e6e25e05711
LABEL maintainer="Purl Contributors"
LABEL org.opencontainers.image.source="https://github.com/ismoilovdevml/purl"
LABEL org.opencontainers.image.title="Purl"
LABEL org.opencontainers.image.description="Lightweight log aggregation system"
LABEL org.opencontainers.image.vendor="Purl"
LABEL org.opencontainers.image.licenses="MIT"

# apt-get upgrade pulls Debian security patches for base-image OS packages so
# the Trivy image scan (fails on fixable HIGH/CRITICAL) stays green. Without it
# the pinned base tag lags behind published security fixes.
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    libssl3 libxml2 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=perl-builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=perl-builder /usr/local/bin /usr/local/bin
COPY lib/ ./lib/
COPY --from=web-builder /app/web/public ./web/public

RUN groupadd -r -g 1000 purl && useradd -r -g purl -u 1000 purl \
    && mkdir -p /app/data /app/config && chown -R purl:purl /app

ENV PURL_HOST=0.0.0.0 \
    PURL_PORT=3000 \
    PURL_CLICKHOUSE_HOST=clickhouse \
    PURL_CLICKHOUSE_PORT=8123 \
    PERL5LIB=/app/lib

EXPOSE 3000
USER purl

# The prefork manager (Purl::API::Server::Prefork, #90) drains gracefully on
# SIGQUIT, SIGTERM and SIGINT alike: workers stop accepting, finish in-flight
# requests, flush their ingest buffers, then exit. SIGQUIT is therefore no
# longer required. It is kept because it is still Mojo's native graceful
# signal, so an image run against an older Purl build (stock Mojo SIGKILLs
# workers on TERM) still drains instead of dropping buffered logs.
#
# The real bound on the drain is the orchestrator's grace period, not Mojo's
# graceful_timeout (120s default, not configurable by Purl): `docker stop`
# SIGKILLs after 10s unless stop_grace_period is set (docker-compose.yml sets
# 60s), Kubernetes after terminationGracePeriodSeconds (chart default 60).
STOPSIGNAL SIGQUIT

# Deliberately the DB-aware endpoint, unlike the Kubernetes livenessProbe
# (which uses /api/health/live). Docker never kills a container for being
# unhealthy, and docker-compose's `depends_on: service_healthy` needs
# "ready to serve", not "process is up".
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

# Prefork server (multiple workers). run() builds a Mojo::Server::Prefork
# from server.workers (PURL_WORKERS, default 4) and runs it in the foreground.
CMD ["perl", "-I/app/lib", "-MPurl::API::Server", "-e", "Purl::API::Server->create->run"]

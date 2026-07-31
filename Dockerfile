# Base images are pinned by DIGEST, not just by tag. A tag is mutable: the
# same `docker build` a week later can produce a different image than the one
# Trivy scanned and cosign signed in CI. Refresh with:
#   docker buildx imagetools inspect <image>:<tag>   # copy the index Digest
# and bump the tag comment alongside it.

# Build web assets — node:20-alpine
FROM node@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS web-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# Perl dependencies builder (build-essential only here, not in final image)
# perl:5.40-slim-bookworm
FROM perl@sha256:48af946921e59d23196ac28a40bdbde5b22b7ba89edce911d3d091468a82ff67 AS perl-builder

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    build-essential libssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://cpanmin.us | perl - App::cpanminus

ENV TAR_OPTIONS="--warning=no-unknown-keyword"

WORKDIR /app
COPY cpanfile ./
RUN cpanm --notest --installdeps .

# Final image (no build-essential = ~400MB smaller)
# perl:5.40-slim-bookworm
FROM perl@sha256:48af946921e59d23196ac28a40bdbde5b22b7ba89edce911d3d091468a82ff67
LABEL maintainer="Purl Contributors"
LABEL org.opencontainers.image.source="https://github.com/ismoilovdevml/purl"
LABEL org.opencontainers.image.title="Purl"
LABEL org.opencontainers.image.description="Lightweight log aggregation system"
LABEL org.opencontainers.image.vendor="Purl"
LABEL org.opencontainers.image.licenses="BSL-1.1"

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

# Prefork manager treats SIGQUIT as "graceful drain" and SIGTERM/SIGINT as
# "kill workers immediately". Make `docker stop` send SIGQUIT so in-flight
# requests finish and workers drain instead of being hard-killed.
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

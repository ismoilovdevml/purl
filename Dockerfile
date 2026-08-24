# Build web assets
FROM node:20-alpine AS web-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

# Perl dependencies builder (build-essential only here, not in final image)
FROM perl:5.43-slim-bookworm AS perl-builder

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    build-essential libssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://cpanmin.us | perl - App::cpanminus

ENV TAR_OPTIONS="--warning=no-unknown-keyword"

WORKDIR /app
COPY cpanfile ./
RUN cpanm --notest --installdeps .

# Final image (no build-essential = ~400MB smaller)
FROM perl:5.43-slim-bookworm
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

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

# Prefork server (multiple workers). run() builds a Mojo::Server::Prefork
# from server.workers (PURL_WORKERS, default 4) and runs it in the foreground.
CMD ["perl", "-I/app/lib", "-MPurl::API::Server", "-e", "Purl::API::Server->create->run"]

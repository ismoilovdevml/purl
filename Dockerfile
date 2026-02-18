# Build web assets
FROM node:20-alpine AS web-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json* ./
RUN npm install
COPY web/ ./
RUN npm run build

# Perl dependencies builder (build-essential only here, not in final image)
FROM perl:5.40-slim-bookworm AS perl-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libssl-dev libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://cpanmin.us | perl - App::cpanminus

WORKDIR /app
COPY cpanfile ./
RUN cpanm --notest --installdeps .

# Final image (no build-essential = ~400MB smaller)
FROM perl:5.40-slim-bookworm
LABEL maintainer="Purl Contributors"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libxml2 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=perl-builder /usr/local/lib/perl5 /usr/local/lib/perl5
COPY --from=perl-builder /usr/local/bin /usr/local/bin
COPY lib/ ./lib/
COPY --from=web-builder /app/web/public ./web/public

RUN groupadd -r purl && useradd -r -g purl purl \
    && mkdir -p /app/data && chown -R purl:purl /app

ENV PURL_HOST=0.0.0.0 \
    PURL_PORT=3000 \
    PURL_CLICKHOUSE_HOST=clickhouse \
    PURL_CLICKHOUSE_PORT=8123 \
    PERL5LIB=/app/lib

EXPOSE 3000
USER purl

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

CMD ["perl", "-I/app/lib", "-MPurl::API::Server", "-e", "Purl::API::Server->create->run"]

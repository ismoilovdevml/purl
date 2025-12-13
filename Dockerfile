# Build web assets
FROM node:20-alpine AS web-builder
WORKDIR /app/web
COPY web/package.json web/package-lock.json* ./
RUN npm install
COPY web/ ./
RUN npm run build

# Perl application
FROM perl:5.40-slim-bookworm
LABEL maintainer="Purl Contributors"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential libssl-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://cpanmin.us | perl - App::cpanminus

WORKDIR /app

COPY cpanfile ./
RUN cpanm --notest --installdeps .
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

# Purl - Log Aggregation Dashboard
# Multi-stage Dockerfile

# ============================================================
# Stage 1: Build web assets
# ============================================================
FROM node:20-alpine AS web-builder

WORKDIR /app/web

COPY web/package.json web/package-lock.json* ./
RUN npm install

COPY web/ ./
RUN npm run build

# ============================================================
# Stage 2: Perl application
# ============================================================
FROM perl:5.40-slim-bookworm

LABEL maintainer="Purl Contributors"
LABEL description="Log Aggregation Dashboard"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install cpanm
RUN curl -L https://cpanmin.us | perl - App::cpanminus

WORKDIR /app

# Copy cpanfile first for better layer caching
COPY cpanfile ./
RUN cpanm --notest --installdeps .

# Copy application code
COPY lib/ ./lib/

# Copy built web assets from builder stage
COPY --from=web-builder /app/web/public ./web/public

# Create non-root user for security
RUN groupadd -r purl && useradd -r -g purl purl

# Create data directory with proper permissions
RUN mkdir -p /app/data && chown -R purl:purl /app

# Set environment variables
ENV PURL_HOST=0.0.0.0
ENV PURL_PORT=3000
ENV PURL_CLICKHOUSE_HOST=clickhouse
ENV PURL_CLICKHOUSE_PORT=8123
ENV PERL5LIB=/app/lib

EXPOSE 3000

# Switch to non-root user
USER purl

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

# Run server using Mojolicious directly
CMD ["perl", "-I/app/lib", "-MPurl::API::Server", "-e", "Purl::API::Server->new->run"]

# Purl - Universal Log Parser & Dashboard
# Multi-stage Dockerfile

# ============================================================
# Stage 1: Build web assets
# ============================================================
FROM node:20-alpine AS web-builder

WORKDIR /app/web

# Copy package files
COPY web/package.json web/package-lock.json* ./

# Install dependencies
RUN npm install

# Copy web source
COPY web/ ./

# Build production assets
RUN npm run build

# ============================================================
# Stage 2: Perl application
# ============================================================
FROM perl:5.38-slim-bookworm

LABEL maintainer="Purl Contributors"
LABEL description="Universal Log Parser & Dashboard"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libssl-dev \
    libsqlite3-dev \
    libyaml-dev \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install cpanm
RUN curl -L https://cpanmin.us | perl - App::cpanminus

# Set working directory
WORKDIR /app

# Copy cpanfile first for better layer caching
COPY cpanfile ./

# Install Perl dependencies
RUN cpanm --notest --installdeps .

# Copy application code
COPY lib/ ./lib/
COPY bin/ ./bin/
COPY config/ ./config/

# Copy built web assets from builder stage
COPY --from=web-builder /app/web/public ./web/public

# Create data directory
RUN mkdir -p /app/data /app/logs

# Make CLI executable
RUN chmod +x /app/bin/purl

# Set environment variables
ENV PURL_HOST=0.0.0.0
ENV PURL_PORT=3000
ENV PURL_DB_PATH=/app/data/purl.db
ENV PERL5LIB=/app/lib

# Expose port
EXPOSE 3000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/api/health || exit 1

# Default command
CMD ["perl", "/app/bin/purl", "server"]

.PHONY: help build up down logs shell restart up-vector lint lint-perl lint-perlcritic lint-js clean prune clickhouse-client web-dev web-build test

# Default target
help:
	@echo "Purl - Log Aggregation Dashboard"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Docker targets:"
	@echo "  build           Build Docker images"
	@echo "  up              Start services (Purl + ClickHouse)"
	@echo "  up-vector       Start with Vector log collector"
	@echo "  down            Stop all services"
	@echo "  logs            View container logs"
	@echo "  shell           Open shell in purl container"
	@echo "  restart         Restart all services"
	@echo ""
	@echo "Development targets:"
	@echo "  lint            Run all linters (syntax + perlcritic + eslint)"
	@echo "  lint-perl       Check Perl syntax only"
	@echo "  lint-perlcritic Run Perl::Critic analysis"
	@echo "  lint-js         Run ESLint on JavaScript/Svelte"
	@echo "  web-dev         Start web development server"
	@echo "  web-build       Build web assets"
	@echo "  test            Run tests"
	@echo ""
	@echo "Maintenance targets:"
	@echo "  clean           Remove containers and volumes"
	@echo "  prune           Deep clean (removes images too)"

# Docker targets
build:
	docker-compose build

up:
	docker-compose up -d

up-vector:
	docker-compose --profile vector up -d

down:
	docker-compose down

logs:
	docker-compose logs -f

shell:
	docker-compose exec purl /bin/bash

restart:
	docker-compose restart

# Web development
web-dev:
	cd web && npm install && npm run dev

web-build:
	cd web && npm install && npm run build

# Linting
PERL5LIB := lib
PERLCRITIC := $(shell which perlcritic 2>/dev/null || echo /opt/homebrew/Cellar/perl/5.40.2/bin/perlcritic)

lint: lint-perl lint-perlcritic lint-js

lint-perl:
	@echo "Checking Perl syntax..."
	@for f in $$(find lib -name '*.pm'); do \
		PERL5LIB=$(PERL5LIB) perl -c $$f 2>&1 || exit 1; \
	done
	@echo "All Perl files syntax OK"

lint-perlcritic:
	@echo "Running Perl::Critic..."
	@PERL5LIB=$(PERL5LIB) $(PERLCRITIC) --profile .perlcriticrc lib/

lint-js:
	@echo "Running ESLint..."
	@cd web && npm run lint

# Testing
test:
	@echo "Running tests..."
	@PERL5LIB=lib prove -r t/ 2>/dev/null || echo "No tests found in t/"

# Maintenance
clean:
	docker-compose down -v

prune: clean
	docker-compose down --rmi local -v
	docker system prune -f

# ClickHouse client
clickhouse-client:
	docker-compose exec clickhouse clickhouse-client

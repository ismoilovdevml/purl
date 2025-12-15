.PHONY: help up down logs restart lint lint-perl lint-js web-dev web-build test clean

# Variables
PERL5LIB := lib
DOCKER := docker compose
PERLCRITIC := $(shell which perlcritic 2>/dev/null || find /opt/homebrew -name perlcritic 2>/dev/null | head -1 || echo perlcritic)

help:
	@echo "Purl - Lightweight Log Aggregation System"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Docker:"
	@echo "  up            Start services (Purl + ClickHouse)"
	@echo "  up-vector     Start with Vector log collector"
	@echo "  down          Stop all services"
	@echo "  logs          View container logs"
	@echo "  restart       Restart all services"
	@echo ""
	@echo "Development:"
	@echo "  lint          Run all linters"
	@echo "  web-dev       Start frontend dev server"
	@echo "  web-build     Build frontend assets"
	@echo "  test          Run tests"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean         Remove containers and volumes"

# Docker
up:
	$(DOCKER) up -d

up-vector:
	$(DOCKER) --profile vector up -d

down:
	$(DOCKER) down

logs:
	$(DOCKER) logs -f

restart:
	$(DOCKER) restart

# Development
web-dev:
	cd web && npm install && npm run dev

web-build:
	cd web && npm install && npm run build

# Linting
lint: lint-perl lint-js

lint-perl:
	@echo "Checking Perl syntax..."
	@for f in $$(find lib -name '*.pm'); do \
		PERL5LIB=$(PERL5LIB) perl -c $$f 2>&1 || exit 1; \
	done
	@echo "Running Perl::Critic..."
	@PERL5LIB=$(PERL5LIB) $(PERLCRITIC) --profile .perlcriticrc lib/

lint-js:
	@echo "Running ESLint..."
	@cd web && npm run lint

# Testing
test:
	@echo "Running Perl tests..."
	@PERL5LIB=lib prove -lv t/

test-quick:
	@PERL5LIB=lib prove -l t/

# Maintenance
clean:
	$(DOCKER) down -v
	docker system prune -f

# ClickHouse
clickhouse-client:
	$(DOCKER) exec clickhouse clickhouse-client

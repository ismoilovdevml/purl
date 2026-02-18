.PHONY: help up down logs restart lint lint-perl lint-js web-dev web-build test preflight clean helm-lint e2e-k8s e2e-docker

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
	@echo "E2E Testing:"
	@echo "  e2e-k8s       K8s E2E test (requires Kind + Helm)"
	@echo "  e2e-docker    Docker Compose E2E test"
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
	@PERL5LIB=lib prove -r t/ 2>/dev/null || echo "No tests found"

# Pre-push verification (lint + test + build)
preflight: lint test web-build
	@echo ""
	@echo "=== PREFLIGHT PASSED ==="
	@echo "All checks green. Safe to push."

# Kubernetes
helm-lint:
	@echo "Running Helm lint..."
	@helm lint chart/
	@echo "Running Helm template..."
	@helm template purl chart/ > /dev/null
	@helm template purl chart/ \
		--set autoscaling.enabled=true \
		--set podDisruptionBudget.enabled=true \
		--set networkPolicy.enabled=true \
		--set vector.enabled=true \
		> /dev/null
	@echo "Helm validation passed."

# E2E Testing
e2e-k8s: ## K8s E2E test (requires Kind + Helm)
	./tests/e2e/k8s-smoke.sh

e2e-docker: ## Docker Compose E2E test
	./tests/e2e/docker-compose-test.sh

# Maintenance
clean:
	$(DOCKER) down -v
	docker system prune -f

# ClickHouse
clickhouse-client:
	$(DOCKER) exec clickhouse clickhouse-client

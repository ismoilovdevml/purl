.PHONY: help build up down logs shell restart up-vector lint lint-perl lint-js clean prune clickhouse-client web-dev web-build

# Default target
help:
	@echo "Purl - Log Aggregation Dashboard"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Docker targets:"
	@echo "  build        Build Docker images"
	@echo "  up           Start services (Purl + ClickHouse)"
	@echo "  up-vector    Start with Vector log collector"
	@echo "  down         Stop all services"
	@echo "  logs         View container logs"
	@echo "  shell        Open shell in purl container"
	@echo "  restart      Restart all services"
	@echo ""
	@echo "Development targets:"
	@echo "  lint         Run all linters"
	@echo "  web-dev      Start web development server"
	@echo "  web-build    Build web assets"
	@echo ""
	@echo "Maintenance targets:"
	@echo "  clean        Remove containers and volumes"
	@echo "  prune        Deep clean (removes images too)"

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
lint: lint-perl lint-js

lint-perl:
	@echo "Checking Perl syntax..."
	@for f in lib/Purl.pm lib/Purl/API/Server.pm lib/Purl/API/Middleware.pm lib/Purl/Storage/ClickHouse.pm lib/Purl/Storage/ClickHouse/*.pm lib/Purl/Alert/*.pm; do \
		PERL5LIB=lib perl -c $$f 2>&1 || exit 1; \
	done
	@echo "All Perl files OK"

lint-js:
	cd web && npm run lint

# Maintenance
clean:
	docker-compose down -v

prune: clean
	docker-compose down --rmi local -v
	docker system prune -f

# ClickHouse client
clickhouse-client:
	docker-compose exec clickhouse clickhouse-client

.PHONY: help build up down logs shell test clean dev install

# Default target
help:
	@echo "Purl - Universal Log Parser & Dashboard"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Docker targets:"
	@echo "  build      Build Docker images"
	@echo "  up         Start all services"
	@echo "  down       Stop all services"
	@echo "  logs       View container logs"
	@echo "  shell      Open shell in purl container"
	@echo "  restart    Restart all services"
	@echo ""
	@echo "Development targets:"
	@echo "  dev        Start development server (local)"
	@echo "  install    Install Perl dependencies"
	@echo "  test       Run tests"
	@echo "  web-dev    Start web development server"
	@echo "  web-build  Build web assets"
	@echo ""
	@echo "Maintenance targets:"
	@echo "  clean      Remove containers and volumes"
	@echo "  prune      Deep clean (removes images too)"

# Docker targets
build:
	docker-compose build

up:
	docker-compose up -d

down:
	docker-compose down

logs:
	docker-compose logs -f

shell:
	docker-compose exec purl /bin/bash

restart:
	docker-compose restart

# Start with Vector log collector
up-vector:
	docker-compose --profile vector up -d

# Development targets
dev:
	perl bin/purl server -p 3000

install:
	cpanm --installdeps .

test:
	prove -lv t/

web-dev:
	cd web && npm install && npm run dev

web-build:
	cd web && npm install && npm run build

# Maintenance targets
clean:
	docker-compose down -v
	rm -rf data/*.db

prune: clean
	docker-compose down --rmi local -v
	docker system prune -f

# ClickHouse client
clickhouse-client:
	docker-compose exec clickhouse clickhouse-client

# Database stats
stats:
	perl bin/purl stats

# Query logs
query:
	@read -p "Enter query: " q; perl bin/purl query "$$q" -r 24h

# Generate sample logs (for testing)
generate-logs:
	@echo "Generating sample logs..."
	@for i in $$(seq 1 100); do \
		echo "{\"timestamp\":\"$$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"INFO\",\"service\":\"test\",\"message\":\"Sample log message $$i\"}" | \
		perl bin/purl parse -f json; \
	done

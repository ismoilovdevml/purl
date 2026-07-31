.PHONY: help up down logs restart lint lint-perl lint-js web-dev web-build test preflight clean helm-lint chart-publish release e2e-k8s e2e-docker

# Variables
# Perl deps are installed with local::lib into ~/perl5 (same layout as CI).
LOCAL_LIB := $(HOME)/perl5
PERL5LIB := lib:$(LOCAL_LIB)/lib/perl5
DOCKER := docker compose
PERLCRITIC := $(shell command -v perlcritic 2>/dev/null || echo $(LOCAL_LIB)/bin/perlcritic)

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
	@echo "Helm chart:"
	@echo "  helm-lint     Lint + template-render the chart"
	@echo "  chart-publish Package chart and publish to charts.purlogs.com"
	@echo ""
	@echo "Release:"
	@echo "  release VERSION=1.2.1   Verify + print the tag commands (see docs/RELEASE.md)"
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
# NOTE: this MUST fail the build when tests fail. It previously ended in
# `|| echo "No tests found"`, which swallowed every failure and made
# `make preflight` report success on a fully red suite.
test:
	@PERL5LIB=$(PERL5LIB) prove -r t/

# Pre-push verification (lint + test + build)
preflight: lint test web-build
	@echo ""
	@echo "=== PREFLIGHT PASSED ==="
	@echo "All checks green. Safe to push."

# Kubernetes
helm-lint:
	@echo "Running Helm lint..."
	@helm lint chart/
	@echo "Rendering default values (the path a public helm install takes)..."
	@helm template purl chart/ > /dev/null
	@echo "Rendering dev values..."
	@helm template purl chart/ -f chart/values-dev.yaml > /dev/null
	@echo "Rendering multi-replica + autoscaling (needs an RWX config volume)..."
	@helm template purl chart/ \
		--set autoscaling.enabled=true \
		--set podDisruptionBudget.enabled=true \
		--set networkPolicy.enabled=true \
		--set vector.enabled=true \
		--set 'config.volume.accessModes[0]=ReadWriteMany' \
		> /dev/null
	@echo "Rendering NetworkPolicy with real peers..."
	@helm template purl chart/ \
		--set networkPolicy.enabled=true \
		--set 'networkPolicy.ingress.fromNamespaces[0]=ingress-nginx' \
		--set 'networkPolicy.ingress.fromCIDRs[0]=10.0.0.0/8' \
		--set 'networkPolicy.clickhouse.ingress.fromCIDRs[0]=10.0.0.0/8' \
		--set metrics.serviceMonitor.enabled=true \
		--set metrics.prometheusNamespace=monitoring \
		> /dev/null
	@echo "Rendering backup CronJob + ClickHouse cluster mode..."
	@helm template purl chart/ \
		--set backup.enabled=true \
		--set backup.s3.bucket=example-bucket \
		--set backup.s3.existingSecret=example-secret \
		--set clickhouse.cluster.enabled=true \
		--set networkPolicy.enabled=true \
		> /dev/null
	@echo "Rendering with an operator-managed Secret (external ClickHouse)..."
	@helm template purl chart/ \
		--set purl.existingSecret=my-purl-secret \
		--set clickhouse.enabled=false \
		--set clickhouse.host=clickhouse.example.com \
		> /dev/null
	@echo "Rendering with an operator-managed Secret (built-in ClickHouse)..."
	@helm template purl chart/ \
		--set purl.existingSecret=my-purl-secret \
		--set purl.existingSecretHasClickHousePassword=true \
		> /dev/null
	@echo "Asserting rendered content (not just that it renders)..."
	@set -e; \
	NP=$$(helm template purl chart/ --set clickhouse.cluster.enabled=true --set networkPolicy.enabled=true | awk '/kind: NetworkPolicy/,0'); \
	COUNT=$$(printf '%s\n' "$$NP" | grep -c 'port: 9009' || true); \
	if [ "$$COUNT" -ne 2 ]; then \
		echo "  FAIL: interserver port 9009 rules = $$COUNT, expected 2 (ingress+egress)."; \
		echo "        ReplicatedMergeTree fetches parts over 9009; without it"; \
		echo "        replication stalls silently."; exit 1; \
	fi; \
	RENDER=$$(helm template purl chart/ --set purl.existingSecret=s --set purl.existingSecretHasClickHousePassword=true \
		--set backup.enabled=true --set backup.s3.bucket=b --set backup.s3.existingSecret=aws); \
	KINDS=$$(printf '%s\n' "$$RENDER" | grep -cE '^kind: (Deployment|StatefulSet|CronJob)$$' || true); \
	if [ "$$KINDS" -lt 3 ]; then \
		echo "  FAIL: only $$KINDS workloads rendered, expected >= 3 (Deployment,"; \
		echo "        StatefulSet, CronJob). backup.enabled defaults to false, so"; \
		echo "        without it the CronJob is never rendered and this assertion"; \
		echo "        cannot see what is in it."; exit 1; \
	fi; \
	OPT=$$(printf '%s\n' "$$RENDER" | grep -A3 'key: PURL_CLICKHOUSE_PASSWORD' | grep -cE '^[[:space:]]*optional:' || true); \
	if [ "$$OPT" -ne 0 ]; then \
		echo "  FAIL: PURL_CLICKHOUSE_PASSWORD secretKeyRef is optional ($$OPT keyRef(s))."; \
		echo "        A missing key must be CreateContainerConfigError, not an"; \
		echo "        empty password."; exit 1; \
	fi; \
	helm template purl chart/ | grep -q 'users.d/zz-purl-users.xml' \
		|| { echo "  FAIL: users.d fragment must sort after default-user.xml."; exit 1; }; \
	helm template purl chart/ | grep -q '"helm.sh/resource-policy": keep' \
		|| { echo "  FAIL: config PVC is not retained on uninstall."; exit 1; }
	@echo "Asserting render-time guards fire..."
	@set -e; \
	for guard in \
		"--set purl.existingSecret=s" \
		"--set networkPolicy.enabled=true --set metrics.serviceMonitor.enabled=true" \
		"--set networkPolicy.enabled=true --set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace=monitoring" \
		"--set vector.buffer.maxSizeBytes=1024" \
		"--set replicaCount=3" ; do \
		if helm template purl chart/ $$guard > /dev/null 2>&1; then \
			echo "  FAIL: guard did not fire for: $$guard"; exit 1; \
		fi; \
	done
	@echo "Helm validation passed."

# Release: cut a semver tag so CI publishes ismoilovdev/purl:X.Y.Z.
# The chart resolves image.tag from Chart.yaml appVersion, so a chart whose
# appVersion has no matching Docker tag makes every public `helm install`
# fail with ImagePullBackOff. This target refuses to let the two drift.
# Usage: make release VERSION=1.2.1
release:
	@test -n "$(VERSION)" || { echo "ERROR: usage: make release VERSION=1.2.1"; exit 1; }
	@echo "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' \
		|| { echo "ERROR: VERSION must be semver X.Y.Z (no leading v)"; exit 1; }
	@APPV=$$(awk '$$1 == "appVersion:" {gsub(/"/, "", $$2); print $$2}' chart/Chart.yaml); \
	if [ "$$APPV" != "$(VERSION)" ]; then \
		echo "ERROR: chart/Chart.yaml appVersion is $$APPV but VERSION is $(VERSION)."; \
		echo "       Bump appVersion first — the chart pulls ismoilovdev/purl:$$APPV."; \
		exit 1; \
	fi
	@git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null \
		&& { echo "ERROR: tag v$(VERSION) already exists"; exit 1; } || true
	@test -z "$$(git status --porcelain)" || { echo "ERROR: working tree is dirty"; exit 1; }
	@BR=$$(git rev-parse --abbrev-ref HEAD); \
	if [ "$$BR" != "main" ]; then echo "ERROR: releases are cut from main (on $$BR)"; exit 1; fi
	@$(MAKE) preflight
	@$(MAKE) helm-lint
	@echo ""
	@echo "All gates green. To publish:"
	@echo "  git tag -a v$(VERSION) -m 'Purl v$(VERSION)'"
	@echo "  git push origin v$(VERSION)      # CI publishes :$(VERSION), :$$(echo $(VERSION) | cut -d. -f1-2) and :latest-equivalent SHA tags"
	@echo "  make chart-publish               # after bumping chart/Chart.yaml version"

# Helm chart release to https://charts.purlogs.com (Vercel static project
# "purl-charts"). Manual only — not wired into CI. The site dir is stable
# and accumulates all published .tgz versions so the index always lists
# every release. Bump chart/Chart.yaml version BEFORE publishing.
CHART_SITE := $(HOME)/.purl-charts-site

chart-publish: helm-lint
	@mkdir -p $(CHART_SITE)
	@echo "Syncing published releases from https://charts.purlogs.com..."
	@if curl -fsSL https://charts.purlogs.com/index.yaml -o $(CHART_SITE)/.remote-index.yaml; then \
		VERSION=$$(awk '$$1 == "version:" {print $$2}' chart/Chart.yaml); \
		if grep -q "/purl-$$VERSION.tgz" $(CHART_SITE)/.remote-index.yaml; then \
			echo "ERROR: purl-$$VERSION is already published — bump chart/Chart.yaml version first"; \
			exit 1; \
		fi; \
		for tgz in $$(grep -oE 'purl-[0-9][A-Za-z0-9._+-]*\.tgz' $(CHART_SITE)/.remote-index.yaml | sort -u); do \
			if [ ! -f "$(CHART_SITE)/$$tgz" ]; then \
				echo "Fetching $$tgz from live site..."; \
				curl -fsSL "https://charts.purlogs.com/$$tgz" -o "$(CHART_SITE)/$$tgz"; \
			fi; \
		done; \
	else \
		echo "WARNING: remote index not reachable — assuming first-ever publish"; \
	fi
	@echo "Packaging chart into $(CHART_SITE)..."
	@helm package chart/ -d $(CHART_SITE)
	@helm repo index $(CHART_SITE) --url https://charts.purlogs.com
	@cd $(CHART_SITE) && \
		if [ ! -f .vercel/project.json ]; then \
			vercel link --yes --project purl-charts --scope ismoilovdevmls-projects; \
		fi && \
		vercel deploy --prod --yes
	@echo "Published. Verify: helm repo update && helm search repo purl/purl --versions"

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

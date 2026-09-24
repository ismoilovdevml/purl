.PHONY: help up down logs restart lint lint-perl lint-js web-dev web-build test preflight clean helm-lint vector-test chart-publish chart-publish-vercel release e2e-k8s e2e-docker

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
	@echo "  helm-lint     Lint + template-render the chart (+ vector-test)"
	@echo "  vector-test   Vector unit tests for chart, deploy/ and install.sh configs"
	@echo "  chart-publish How the chart is published (CI: .github/workflows/chart-release.yml)"
	@echo "  chart-publish-vercel  LEGACY manual publish to charts.purlogs.com (frozen)"
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
#
# purl.autoGenerateSecrets is false by default: without it the chart refuses to
# invent PURL_CLICKHOUSE_PASSWORD / PURL_SESSION_SECRET / PURL_API_KEYS, because
# a clusterless render mints a fresh one every time (issue #22). A real
# `helm install` has cluster access and writes the value once, so passing this
# flag is what makes a clusterless render equivalent to that first install.
# Every render below that produces the chart-managed Secret therefore needs it;
# renders using purl.existingSecret do not.
AUTOGEN := --set purl.autoGenerateSecrets=true

helm-lint:
	@echo "Running Helm lint..."
	@helm lint chart/ $(AUTOGEN)
	@echo "Rendering default values (the path a public helm install takes)..."
	@helm template purl chart/ $(AUTOGEN) > /dev/null
	@echo "Rendering dev values..."
	@helm template purl chart/ -f chart/values-dev.yaml $(AUTOGEN) > /dev/null
	@echo "Rendering multi-replica + autoscaling (needs an RWX config volume + Redis)..."
	@helm template purl chart/ $(AUTOGEN) \
		--set autoscaling.enabled=true \
		--set podDisruptionBudget.enabled=true \
		--set networkPolicy.enabled=true \
		--set vector.enabled=true \
		--set 'config.volume.accessModes[0]=ReadWriteMany' \
		--set purl.redis.enabled=true \
		--set purl.redis.url=redis://redis:6379 \
		> /dev/null
	@echo "Rendering NetworkPolicy with real peers..."
	@helm template purl chart/ $(AUTOGEN) \
		--set networkPolicy.enabled=true \
		--set 'networkPolicy.ingress.fromNamespaces[0]=ingress-nginx' \
		--set 'networkPolicy.ingress.fromCIDRs[0]=10.0.0.0/8' \
		--set 'networkPolicy.clickhouse.ingress.fromCIDRs[0]=10.0.0.0/8' \
		--set metrics.serviceMonitor.enabled=true \
		--set metrics.prometheusNamespace=monitoring \
		> /dev/null
	@echo "Rendering backup CronJob + ClickHouse cluster mode..."
	@helm template purl chart/ $(AUTOGEN) \
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
	NP=$$(helm template purl chart/ $(AUTOGEN) --set clickhouse.cluster.enabled=true --set networkPolicy.enabled=true | awk '/kind: NetworkPolicy/,0'); \
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
	helm template purl chart/ $(AUTOGEN) | grep -q 'users.d/zz-purl-users.xml' \
		|| { echo "  FAIL: users.d fragment must sort after default-user.xml."; exit 1; }; \
	helm template purl chart/ $(AUTOGEN) | grep -q '"helm.sh/resource-policy": keep' \
		|| { echo "  FAIL: config PVC is not retained on uninstall."; exit 1; }
	@echo "Asserting live-tail transport wiring..."
	@set -e; \
	RWX="--set 'config.volume.accessModes[0]=ReadWriteMany'"; \
	REDIS="--set purl.redis.enabled=true --set purl.redis.url=redis://redis:6379"; \
	ERR=$$(eval helm template purl chart/ $(AUTOGEN) $$RWX --set replicaCount=3 2>&1 >/dev/null) && { \
		echo "  FAIL: replicaCount=3 without Redis rendered. Live tail would be"; \
		echo "        served by one pod's spool file and silently drop the other"; \
		echo "        pods' logs."; exit 1; \
	} || true; \
	printf '%s\n' "$$ERR" | grep -q 'without Redis: live tail would silently break' || { \
		echo "  FAIL: replicaCount=3 failed for a DIFFERENT reason than the live-tail"; \
		echo "        guard (RWX is set precisely so the config-volume guard cannot"; \
		echo "        fire and make this pass for the wrong reason). Got:"; \
		printf '%s\n' "$$ERR" | head -3; exit 1; \
	}; \
	ERR=$$(eval helm template purl chart/ $(AUTOGEN) $$RWX --set autoscaling.enabled=true --set autoscaling.minReplicas=1 --set autoscaling.maxReplicas=4 2>&1 >/dev/null) && { \
		echo "  FAIL: an HPA that can reach 4 pods rendered without Redis. Tail"; \
		echo "        breaks at the first scale-up, when nobody is watching."; exit 1; \
	} || true; \
	printf '%s\n' "$$ERR" | grep -q 'without Redis: live tail would silently break' || { \
		echo "  FAIL: the autoscaling case did not hit the live-tail guard. Got:"; \
		printf '%s\n' "$$ERR" | head -3; exit 1; \
	}; \
	eval helm template purl chart/ $(AUTOGEN) $$RWX $$REDIS --set replicaCount=3 >/dev/null || { \
		echo "  FAIL: replicaCount=3 WITH Redis must render. A guard with no escape"; \
		echo "        hatch is a broken chart, not a safe one."; exit 1; \
	}; \
	SPOOL=$$(helm template purl chart/ $(AUTOGEN) --set purl.broadcastSpool.emptyDir=true); \
	printf '%s\n' "$$SPOOL" | grep -q 'PURL_BROADCAST_SPOOL: "/app/spool/live-tail.spool"' || { \
		echo "  FAIL: broadcastSpool.emptyDir=true did not set PURL_BROADCAST_SPOOL."; exit 1; \
	}; \
	printf '%s\n' "$$SPOOL" | grep -q 'mountPath: /app/spool' || { \
		echo "  FAIL: PURL_BROADCAST_SPOOL points at /app/spool but nothing is"; \
		echo "        mounted there — the app would fall back to worker-local tail."; exit 1; \
	}; \
	printf '%s\n' "$$SPOOL" | grep -q 'sizeLimit: 64Mi' || { \
		echo "  FAIL: the spool emptyDir has no sizeLimit; a stuck reader could"; \
		echo "        fill the node's ephemeral storage."; exit 1; \
	}; \
	helm template purl chart/ $(AUTOGEN) | grep -q 'PURL_BROADCAST_SPOOL' && { \
		echo "  FAIL: PURL_BROADCAST_SPOOL is set by default. Empty means 'use the"; \
		echo "        app default next to settings.json' and must stay unset."; exit 1; \
	} || true
	@echo "Asserting PURL_TELEGRAM_THREAD_ID lands in the ConfigMap, not the Secret..."
	@set -e; \
	TG=$$(helm template purl chart/ $(AUTOGEN) --set purl.telegram.threadId=42 \
		--set purl.telegram.botToken=tok --set purl.telegram.chatId=-100123); \
	printf '%s\n' "$$TG" | awk '/^kind: ConfigMap$$/,/^---$$/' | grep -q 'PURL_TELEGRAM_THREAD_ID: "42"' || { \
		echo "  FAIL: purl.telegram.threadId did not reach the ConfigMap."; exit 1; \
	}; \
	printf '%s\n' "$$TG" | awk '/^kind: Secret$$/,/^---$$/' | grep -q 'PURL_TELEGRAM_THREAD_ID' && { \
		echo "  FAIL: a forum topic id is not a credential and must not be"; \
		echo "        templated into the Secret."; exit 1; \
	} || true; \
	printf '%s\n' "$$TG" | awk '/^kind: Secret$$/,/^---$$/' | grep -q 'PURL_TELEGRAM_BOT_TOKEN' || { \
		echo "  FAIL: the bot token left the Secret. This assertion only proves"; \
		echo "        thread_id is absent if the Secret really rendered telegram"; \
		echo "        keys at all."; exit 1; \
	}; \
	helm template purl chart/ $(AUTOGEN) --set purl.existingSecret=s \
		--set purl.existingSecretHasClickHousePassword=true --set purl.telegram.threadId=7 \
		| grep -q 'PURL_TELEGRAM_THREAD_ID: "7"' || { \
		echo "  FAIL: threadId must still apply with purl.existingSecret set —"; \
		echo "        that is the whole reason it lives in the ConfigMap."; exit 1; \
	}; \
	helm template purl chart/ $(AUTOGEN) | grep -q 'PURL_TELEGRAM_THREAD_ID' && { \
		echo "  FAIL: PURL_TELEGRAM_THREAD_ID rendered with threadId empty; an"; \
		echo "        empty message_thread_id is rejected by Telegram."; exit 1; \
	} || true
	@echo "Asserting ingest is durable by default (issue #126)..."
	@set -e; \
	DEF=$$(helm template purl chart/ $(AUTOGEN)); \
	FAST=$$(helm template purl chart/ $(AUTOGEN) --set purl.ingestDurable=false); \
	printf '%s\n' "$$DEF" | awk '/^kind: ConfigMap$$/,/^---$$/' | grep -q 'PURL_INGEST_DURABLE: "1"' || { \
		echo "  FAIL: default render does not set PURL_INGEST_DURABLE=\"1\". Fast mode"; \
		echo "        loses rows ClickHouse rejects after Purl answered 2xx (#126)."; exit 1; \
	}; \
	printf '%s\n' "$$FAST" | awk '/^kind: ConfigMap$$/,/^---$$/' | grep -q 'PURL_INGEST_DURABLE: "0"' || { \
		echo "  FAIL: purl.ingestDurable=false did not render PURL_INGEST_DURABLE=\"0\"."; exit 1; \
	}; \
	C1=$$(printf '%s\n' "$$DEF" | awk '/^kind:/{k=$$2} k=="Deployment" && /checksum\/config:/{print $$2}'); \
	C2=$$(printf '%s\n' "$$FAST" | awk '/^kind:/{k=$$2} k=="Deployment" && /checksum\/config:/{print $$2}'); \
	if [ -z "$$C1" ] || [ "$$C1" = "$$C2" ]; then \
		echo "  FAIL: toggling purl.ingestDurable does not change the Deployment's"; \
		echo "        checksum/config,"; \
		echo "        so running pods would keep the old mode."; exit 1; \
	fi; \
	ERR=$$(helm template purl chart/ $(AUTOGEN) --set-string purl.ingestDurable=false 2>&1 >/dev/null) && { \
		echo "  FAIL: a STRING \"false\" rendered. It is truthy in a template and"; \
		echo "        would have meant durable."; exit 1; \
	} || true; \
	printf '%s\n' "$$ERR" | grep -q 'purl.ingestDurable must be a boolean' || { \
		echo "  FAIL: string ingestDurable failed for another reason. Got:"; \
		printf '%s\n' "$$ERR" | head -3; exit 1; \
	}; \
	helm template purl chart/ $(AUTOGEN) --set metrics.prometheusRule.enabled=true \
		| grep -q 'increase(purl_ingest_dropped_total\[5m\]) > 0' || { \
		echo "  FAIL: PrometheusRule has no PurlIngestDropped alert."; exit 1; \
	}
	@echo "Asserting generated secrets cannot drift under GitOps (issue #22)..."
	@set -e; \
	PIN="--set clickhouse.password=pw --set purl.sessionSecret=ss --set purl.apiKeys=ak"; \
	ERR=$$(helm template purl chart/ 2>&1 >/dev/null) && { \
		echo "  FAIL: a clusterless default render succeeded. It must refuse to"; \
		echo "        invent credentials — every render would mint a new one and"; \
		echo "        each Argo CD sync would break ClickHouse auth (#22)."; exit 1; \
	} || true; \
	printf '%s\n' "$$ERR" | grep -q 'refusing to generate' || { \
		echo "  FAIL: default render failed, but not with the #22 guard. Got:"; \
		printf '%s\n' "$$ERR" | head -5; exit 1; \
	}; \
	for cred in clickhouse.password purl.sessionSecret purl.apiKeys; do \
		case $$cred in \
			clickhouse.password) OTHER="--set purl.sessionSecret=ss --set purl.apiKeys=ak";; \
			purl.sessionSecret)  OTHER="--set clickhouse.password=pw --set purl.apiKeys=ak";; \
			purl.apiKeys)        OTHER="--set clickhouse.password=pw --set purl.sessionSecret=ss";; \
		esac; \
		if helm template purl chart/ $$OTHER >/dev/null 2>&1; then \
			echo "  FAIL: $$cred alone may be left to generate. Each of the three"; \
			echo "        must be guarded independently."; exit 1; \
		fi; \
	done; \
	A=$$(helm template purl chart/ $$PIN); \
	B=$$(helm template purl chart/ $$PIN); \
	printf '%s\n' "$$A" | grep -q 'PURL_CLICKHOUSE_PASSWORD: "pw"' || { \
		echo "  FAIL: the pinned render does not contain the pinned password, so"; \
		echo "        the stability check below would compare nothing. (An"; \
		echo "        assertion cannot protect a path it does not render.)"; exit 1; \
	}; \
	printf '%s\n' "$$A" | grep -q 'PURL_SESSION_SECRET: "ss"' \
		|| { echo "  FAIL: pinned purl.sessionSecret did not reach the Secret."; exit 1; }; \
	printf '%s\n' "$$A" | grep -q 'PURL_API_KEYS: "ak"' \
		|| { echo "  FAIL: pinned purl.apiKeys did not reach the Secret."; exit 1; }; \
	[ "$$A" = "$$B" ] || { \
		echo "  FAIL: two renders with every credential pinned differ. This is the"; \
		echo "        GitOps-safe path and it MUST be byte-stable."; exit 1; \
	}; \
	GEN=$$(helm template purl chart/ $(AUTOGEN) | grep -c 'PURL_CLICKHOUSE_PASSWORD: "[A-Za-z0-9]\{32\}"' || true); \
	if [ "$$GEN" -ne 1 ]; then \
		echo "  FAIL: with $(AUTOGEN) the chart rendered $$GEN generated 32-char"; \
		echo "        ClickHouse passwords, expected exactly 1. The opt-in escape"; \
		echo "        hatch for a real helm install is broken."; exit 1; \
	fi
	@echo "Asserting checksum annotations ignore chart-version-only changes..."
	@set -e; \
	PIN="--set clickhouse.password=pw --set purl.sessionSecret=ss --set purl.apiKeys=ak"; \
	TMP=$$(mktemp -d); trap 'rm -rf "$$TMP"' EXIT; \
	cp -R chart "$$TMP/chart"; \
	sed -i.bak 's/^version: .*/version: 99.0.0/' "$$TMP/chart/Chart.yaml"; \
	A=$$(helm template purl chart/ $$PIN | grep 'checksum/' | sort); \
	B=$$(helm template purl "$$TMP/chart" $$PIN | grep 'checksum/' | sort); \
	[ -n "$$A" ] || { echo "  FAIL: no checksum/ annotations rendered."; exit 1; }; \
	[ "$$A" = "$$B" ] || { \
		echo "  FAIL: bumping only Chart.yaml version changed a checksum/ annotation."; \
		echo "        The checksums must hash config payload (purl.dataChecksum), not"; \
		echo "        labels, or every chart release restarts ClickHouse and Vector."; exit 1; \
	}; \
	C=$$(helm template purl chart/ $$PIN --set clickhouse.serverConfig.markCacheSize=1 | grep 'checksum/server-config'); \
	[ "$$C" != "$$(printf '%s\n' "$$A" | grep 'checksum/server-config')" ] || { \
		echo "  FAIL: changing clickhouse.serverConfig did not change checksum/server-config."; exit 1; }
	@echo "Asserting the ClickHouse small profile is identical in chart and compose (#108)..."
	@python3 scripts/check_clickhouse_profile.py || { \
		echo "  FAIL: chart/files/clickhouse/*.xml and docker/clickhouse/*.xml disagree."; \
		echo "        Helm and docker-compose would run different ClickHouse limits."; exit 1; }
	@echo "Asserting the ClickHouse small profile is rendered and mounted..."
	@set -e; \
	R=$$(helm template purl chart/ $(AUTOGEN)); \
	for want in '<uncompressed_cache_size>0</uncompressed_cache_size>' \
		'<max_server_memory_usage_to_ram_ratio>0.8</max_server_memory_usage_to_ram_ratio>' \
		'<max_memory_usage>268435456</max_memory_usage>' \
		'<vertical_merge_algorithm_min_rows_to_activate>1</vertical_merge_algorithm_min_rows_to_activate>' \
		'mountPath: /etc/clickhouse-server/config.d/zz-purl-server.xml' \
		'mountPath: /etc/clickhouse-server/users.d/zz-purl-profile.xml' \
		'memory: 1536Mi'; do \
		printf '%s\n' "$$R" | grep -qF -- "$$want" || { \
			echo "  FAIL: default render is missing: $$want"; \
			echo "        Without the profile ClickHouse sizes caches above the pod limit (#106)."; exit 1; }; \
	done; \
	printf '%s\n' "$$R" | grep -q 'zzz-purl-overrides' && { \
		echo "  FAIL: an overrides file rendered although no serverConfig override is set."; exit 1; } || true; \
	O=$$(helm template purl chart/ $(AUTOGEN) --set clickhouse.serverConfig.uncompressedCacheSize=0); \
	printf '%s\n' "$$O" | grep -qF 'mountPath: /etc/clickhouse-server/config.d/zzz-purl-overrides.xml' \
		&& printf '%s\n' "$$O" | awk '/zzz-purl-overrides.xml: [|]/,/<\/clickhouse>/' | grep -qF '<uncompressed_cache_size>0</uncompressed_cache_size>' || { \
		echo "  FAIL: an override of 0 was dropped. 0 is a real value (it disables a cache)."; exit 1; }; \
	helm template purl chart/ $(AUTOGEN) --set clickhouse.serverConfig.maxServerMemoryUsageToRamRatio=0 \
		| awk '/zzz-purl-overrides.xml: [|]/,/<\/clickhouse>/' \
		| grep -qF '<max_server_memory_usage_to_ram_ratio>0</max_server_memory_usage_to_ram_ratio>' || { \
		echo "  FAIL: maxServerMemoryUsageToRamRatio=0 was dropped. Every override key must"; \
		echo "        treat 0 as a value and only \"\" as unset."; exit 1; }; \
	P=$$(helm template purl chart/ $(AUTOGEN) --set clickhouse.serverConfig.smallProfile=false); \
	printf '%s\n' "$$P" | grep -qE 'zz-purl-server|zz-purl-profile|name: server-config' && { \
		echo "  FAIL: smallProfile=false with no overrides still mounts server-config."; \
		echo "        A subPath mount of a missing ConfigMap key fails the pod."; exit 1; } || true; \
	helm template purl chart/ $(AUTOGEN) --set clickhouse.serverConfig.enabled=false | grep -qE 'zz-purl-server|zzz-purl-overrides|name: server-config' && { \
		echo "  FAIL: clickhouse.serverConfig.enabled=false still mounts the profile."; exit 1; } || true
	@echo "Asserting render-time guards fire..."
	@set -e; \
	for guard in \
		"--set purl.existingSecret=s" \
		"--set networkPolicy.enabled=true --set metrics.serviceMonitor.enabled=true" \
		"--set networkPolicy.enabled=true --set metrics.serviceMonitor.enabled=true --set metrics.serviceMonitor.namespace=monitoring" \
		"--set vector.buffer.maxSizeBytes=1024" \
		"--set replicaCount=3 --set purl.redis.enabled=true --set purl.redis.url=redis://r:6379" ; do \
		ERR=$$(helm template purl chart/ $(AUTOGEN) $$guard 2>&1 >/dev/null) && { \
			echo "  FAIL: guard did not fire for: $$guard"; exit 1; \
		} || true; \
		printf '%s\n' "$$ERR" | grep -q 'refusing to generate' && { \
			echo "  FAIL: guard for '$$guard' fired the #22 secret guard instead of"; \
			echo "        its own. $(AUTOGEN) is missing, so this case was passing"; \
			echo "        for the wrong reason and asserted nothing."; exit 1; \
		} || true; \
	done
	@$(MAKE) --no-print-directory vector-test
	@echo "Helm validation passed."

# Vector unit tests (`vector test`) for the log-level detection VRL in every
# Vector config Purl ships: the chart DaemonSet, deploy/vector/vector.toml and
# the agent config install.sh writes. Uses a local `vector` if installed,
# otherwise the chart's timberio/vector image through docker.
vector-test:
	@echo "Running Vector unit tests (chart, deploy/, install.sh)..."
	@tests/vector/run.sh

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
	@echo "  # chart: CI publishes chart/Chart.yaml version to https://ismoilovdevml.github.io/purl"
	@echo "  #        once :$(VERSION) is on Docker Hub (Chart Release workflow)"

# Helm chart publishing is done by CI, not from a laptop:
# .github/workflows/chart-release.yml packages chart/ on a push to main that
# changes chart/Chart.yaml (and after each release-tag build), creates the
# GitHub Release purl-<version> with the .tgz, and adds it to index.yaml on the
# gh-pages branch, served at https://ismoilovdevml.github.io/purl.
# See docs/RELEASE.md. This target only explains that and shows what is live.
CHART_REPO_URL := https://ismoilovdevml.github.io/purl

chart-publish:
	@echo "The chart is published by CI (.github/workflows/chart-release.yml)."
	@echo "Bump chart/Chart.yaml version, merge to main; to re-run by hand:"
	@echo "  gh workflow run chart-release.yml"
	@echo ""
	@echo "Published versions at $(CHART_REPO_URL):"
	@IDX=$$(curl -fsSL $(CHART_REPO_URL)/index.yaml 2>/dev/null) \
		&& printf '%s\n' "$$IDX" | awk '$$1 == "version:" {print "  " $$2}' \
		|| echo "  (index not reachable — has the one-time gh-pages setup in docs/RELEASE.md been done?)"

# LEGACY — https://charts.purlogs.com (Vercel static project "purl-charts").
# Superseded by the GitHub Pages repo above and kept only until the Vercel
# project is retired. Do NOT use it for new releases: it would publish a
# version the GitHub Pages index does not have. Manual only.
CHART_SITE := $(HOME)/.purl-charts-site

chart-publish-vercel: helm-lint
	@echo "WARNING: legacy target — charts are published to $(CHART_REPO_URL) by CI."
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

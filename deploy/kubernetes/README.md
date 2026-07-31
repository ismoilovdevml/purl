# deploy/kubernetes — UNMAINTAINED

**Do not use this for new installs. Use the Helm chart in [`chart/`](../../chart/).**

```bash
helm repo add purl https://charts.purlogs.com
helm install purl purl/purl --namespace purl --create-namespace
```

## Why this is here

These raw manifests predate the Helm chart. The chart now templates
everything in this directory and is the only deploy path that receives
hardening, review and CI validation. The manifests are kept only because
existing installs and older documentation still reference them; they are
frozen, not maintained.

Tracked in [issue #41](https://github.com/ismoilovdevml/purl/issues/41).

## What you do NOT get here

Every item below ships in `chart/` and is absent from these manifests:

| Missing here | Chart equivalent |
|---|---|
| Password generation — `secret.yaml` ships literal `CHANGE_ME` placeholders | Random 32-char ClickHouse password + session secret + API key, stable across upgrades |
| Any `securityContext` on ClickHouse, Purl or Vector — all run as root with the default context | Pod Security Standards `restricted` contexts (`chart/values.yaml`: `podSecurityContext`, `securityContext`) |
| Config persistence — dashboard users, license and `settings.json` live in an `emptyDir` and are wiped on every restart | `config.volume.enabled=true` PVC, annotated `helm.sh/resource-policy: keep` |
| ClickHouse `default` user restriction and `access_management` lockdown | `clickhouse.restrictDefaultUser`, `clickhouse.defaultAccessManagement` |
| Application-user provisioning with a real password | `clickhouse-users-config.yaml` (`users.d/zz-purl-users.xml`) |
| NetworkPolicy allow-list; the one here is the old unconditional shape | `networkPolicy.*`, including the ClickHouse policy and interserver port 9009 |
| Scheduled ClickHouse → S3 backups | `backup.*` CronJob |
| PodDisruptionBudgets that do not deadlock `kubectl drain` | `podDisruptionBudget.*` |
| Prometheus ServiceMonitor / PrometheusRule | `metrics.*` |
| Render-time guards against misconfiguration | `fail` guards throughout `chart/templates/` |

`install.sh` here also refuses to run without an explicit acknowledgement —
set `PURL_ACCEPT_UNMAINTAINED=1` if you genuinely need the legacy path.

## Migrating to the chart

There is no in-place upgrade. ClickHouse data lives on the
`clickhouse-data` PVC and can be reused:

1. Note your existing PVC name: `kubectl -n purl get pvc`
2. Install the chart into a new namespace pointing at your existing
   ClickHouse (`clickhouse.enabled=false`, `clickhouse.host=...`), or take a
   backup and restore into a fresh chart install.
3. Delete the old resources: `kubectl delete -k deploy/kubernetes/`

## Trivy

The 9 HIGH IaC findings in this directory (`KSV-0014`, `KSV-0118`) are
path-scoped in `/.trivyignore.yaml` rather than fixed. They are real, they
are the reason this path is deprecated, and hardening them would mean
maintaining a second copy of the chart. The scan gates `chart/`, `Dockerfile`
and `deploy/` everywhere else.

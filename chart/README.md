# Purl Helm chart

Self-hosted log aggregation: a Purl deployment, ClickHouse, an optional Vector
DaemonSet for node log collection, and an optional S3 backup CronJob.

```bash
helm repo add purl https://charts.purlogs.com
helm repo update
helm install purl purl/purl -n purl --create-namespace
```

`helm show values purl/purl` is the full reference — every key in
`values.yaml` carries its rationale inline. This file covers the things a
values listing cannot tell you: what breaks on upgrade, and how the storage
behaves.

## Versioning

Two version numbers, deliberately independent:

| Field        | Meaning                                                          |
|--------------|------------------------------------------------------------------|
| `version`    | The **chart**. Bumped when templates or values change.            |
| `appVersion` | The **Purl image** (`ismoilovdev/purl:<appVersion>`) it deploys.  |

`CHANGELOG.md` at the repo root tracks the **application**, not the chart —
its `## [1.2.0]` is the app release of 2025-12-15 and has nothing to do with
chart 1.2.0. Chart-level changes are described here.

The chart follows semver against its **values contract**: a value set that
rendered on `X.Y.*` must keep rendering on `X.(Y+1).*`. A guard that rejects
previously valid values is a MAJOR bump, which is why the release after 1.1.0
is 2.0.0 and not 1.2.0.

## Upgrading to 2.0.0

`helm upgrade` from 1.x **fails at render time** for the value sets below.
Failing to render is the intended behaviour: each guard replaces a
misconfiguration that used to install cleanly and then go wrong quietly. Fix
the values first, then upgrade — nothing is applied to the cluster until the
render succeeds, so a rejected upgrade leaves the running release untouched.

Dry-run first; it reproduces every guard without touching the release:

```bash
helm upgrade --dry-run purl purl/purl -n purl -f my-values.yaml
```

### 1. `purl.existingSecret` with the built-in ClickHouse

**Fails if:** `purl.existingSecret` is set and `clickhouse.enabled=true`
(the default).

The chart cannot read your Secret, so it cannot verify that
`PURL_CLICKHOUSE_PASSWORD` is in it. That key is mandatory with the built-in
ClickHouse: without it ClickHouse previously started with an **empty
password** while still accepting connections from
`clickhouse.allowedNetworks` (default `::/0`) — any pod in the cluster could
read and write the log database.

```yaml
purl:
  existingSecret: my-purl-secret
  # Add PURL_CLICKHOUSE_PASSWORD to that Secret, then assert it here:
  existingSecretHasClickHousePassword: true
```

Or point at an external database instead: `clickhouse.enabled: false` plus
`clickhouse.host`.

Assert this **only** when the key is really present. Related, and also new in
2.0.0: `optional: true` is gone from every `PURL_CLICKHOUSE_PASSWORD`
`secretKeyRef` — the Purl Deployment, the ClickHouse StatefulSet and the
backup CronJob. A missing key is now a loud `CreateContainerConfigError` on
the pod instead of an empty password (and, for the CronJob, instead of
scheduled backups that fail authentication silently and are discovered at
restore time).

### 2. `metrics.serviceMonitor.namespace` renamed to `metrics.prometheusNamespace`

**Fails if:** `metrics.serviceMonitor.namespace` is set (rename it), or if
`metrics.serviceMonitor.enabled=true` and `networkPolicy.enabled=true` and
neither is set.

```yaml
metrics:
  prometheusNamespace: monitoring   # was: metrics.serviceMonitor.namespace
  serviceMonitor:
    enabled: true
```

The value is the namespace **Prometheus itself runs in**. It does not place
the ServiceMonitor — that object is always created in the release namespace —
and its only consumer is the NetworkPolicy scrape rule. Nested under
`serviceMonitor` it read as "the namespace to create the ServiceMonitor in",
which is what the key means in most other charts; a user who set it to their
own release namespace, the natural reading, left Prometheus blocked.

It is required rather than defaulted because the rule opens `purl.port`, and
`purl.port` is the application port — the one serving `/api/logs` and the
dashboard, not a separate metrics port. In 1.x the rule was
`namespaceSelector: {}`, so turning on metrics reopened the whole allow-list
to every namespace in the cluster. `networkPolicy.ingress.extraFrom` does not
satisfy the guard; to render without setting it, turn off
`metrics.serviceMonitor.enabled` or `networkPolicy.enabled`.

### 3. The config PVC now survives `helm uninstall`

Not a render failure — a behaviour change. `config.volume.keepOnUninstall` is
new and defaults to `true`, adding `helm.sh/resource-policy: keep` to the
`<release>-purl-config` PVC. In 1.x, `helm uninstall` deleted it, taking every
dashboard login and the license key with it while every log line survived on
ClickHouse's own (non-Helm-managed) PVC.

Read the "Config volume" section below before changing that volume: `keep`
has two consequences the annotation does not advertise.

### 4. Wider ClickHouse NetworkPolicy peers

`networkPolicy.clickhouse.ingress.extraFrom` peers are now allowed on the
native protocol port 9000 as well as the HTTP port. Those peers are documented
as a DBA namespace or an external ETL pod, and both speak the native protocol
— `clickhouse-client`, the Go/Python drivers and the JDBC/ODBC bridges all
connect on 9000. `networkPolicy.clickhouse.ingress.fromCIDRs` is unchanged and
stays HTTP-only: it exists for kubelet probes, which never need 9000.

## Config volume

`<release>-purl-config` holds dashboard users, the license key and
`settings.json`. With `config.volume.keepOnUninstall: true` (default) it is
annotated `helm.sh/resource-policy: keep`.

**`keep` stops deletion, not mutation.** A PVC spec is immutable. Changing
`config.volume.size` or `config.volume.storageClass` on an existing release
makes Helm patch the live PVC, the API server reject the patch, and the
**entire `helm upgrade` fail** — so an unrelated image bump in the same
upgrade also stops deploying. `helm uninstall && helm install` is not a way
out either: `keep` preserves the PVC and the reinstall hits the same conflict.

If your storage class sets `allowVolumeExpansion: true`, grow in place and
then match the value — no uninstall:

```bash
kubectl -n purl patch pvc purl-config \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'
helm upgrade purl purl/purl -n purl --set config.volume.size=5Gi
```

Otherwise the volume has to be replaced by hand, which **destroys the logins
and license** unless you restore them:

```bash
kubectl -n purl get pvc purl-config -o yaml > config-pvc-backup.yaml
helm -n purl uninstall purl
kubectl -n purl delete pvc purl-config
helm -n purl install purl purl/purl --set config.volume.size=5Gi
```

Reinstall with the **same release name and namespace**. A different release
name fails on `invalid ownership metadata` against the surviving PVC.

**`config.volume.enabled=false` orphans it silently.** The PVC leaves the
rendered manifest, `keep` stops Helm deleting it, and the PVC and its PV stay
bound and billed with no message — still holding the old logins and license.
Check for it yourself:

```bash
kubectl -n purl get pvc purl-config
kubectl -n purl delete pvc purl-config   # when you meant to drop it
```

ClickHouse's data PVC is a StatefulSet `volumeClaimTemplate` and is never
Helm-managed: `helm uninstall` never deletes your logs, and `keep` is
irrelevant to it.

## Other things that fail at render time

These predate 2.0.0 and are unchanged, listed because the messages are the
only documentation of them:

- `backup.enabled=true` without `backup.s3.bucket` / `backup.s3.existingSecret`
- `purl.redis.enabled=true` without `purl.redis.url`
- `config.volume.accessModes: [ReadWriteOnce]` with more than one replica
  (`replicaCount`, or `autoscaling.maxReplicas`), or with
  `updateStrategy.type: RollingUpdate`
- `clickhouse.user` that is not a valid identifier — it becomes an XML element
  name in the ClickHouse `users.d` config
- empty `clickhouse.allowedNetworks`
- `vector.buffer.maxSizeBytes` below Vector's 268435488-byte minimum

## Validating a change to this chart

```bash
make helm-lint
```

Renders every supported shape, then asserts on the rendered content — the
interserver 9009 rules, the absence of `optional:` on the ClickHouse password,
the `users.d` fragment name, the PVC retention annotation — and asserts that
each render-time guard above still fires. `.github/workflows/ci.yml`
(`k8s-validate`) runs the same set. Both pin the same Helm version; keep them
in step.

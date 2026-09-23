# Purl Helm chart

Self-hosted log aggregation: a Purl deployment, ClickHouse, an optional Vector
DaemonSet for node log collection, and an optional S3 backup CronJob.

```bash
helm repo add purl https://ismoilovdevml.github.io/purl
helm repo update
helm install purl purl/purl -n purl --create-namespace
```

The repo is served from GitHub Pages; every chart version is also a GitHub
Release (`purl-<version>`) carrying the `.tgz`. It replaces
`https://charts.purlogs.com` — if you added that URL, run
`helm repo remove purl` and add the one above.

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

## 2.1.3

- New `clickhouse.serverConfig` block, rendered to
  `config.d/zz-purl-server.xml` and mounted into ClickHouse. It bounds server
  memory and caches, which ClickHouse otherwise sizes for a large dedicated
  host. Mark, index-mark and primary-index caches default to 5 GiB and the
  uncompressed cache to 8 GiB, each above a typical pod limit. Unbounded, the
  uncompressed cache filled a 5 GiB pod in about 12 minutes of ingest and
  search. Every query then failed with `MEMORY_LIMIT_EXCEEDED` and the
  dashboard went down. The new defaults:

  | Key | Default | ClickHouse default |
  |-----|---------|--------------------|
  | `maxServerMemoryUsageToRamRatio` | 0.8 | 0.9 |
  | `uncompressedCacheSize` | 256 MiB | 8 GiB |
  | `markCacheSize` | 256 MiB | 5 GiB |
  | `indexMarkCacheSize` | 64 MiB | 5 GiB |
  | `primaryIndexCacheSize` | 128 MiB | 5 GiB |
  | `queryConditionCacheSize` | 64 MiB | ~100 MiB |
  | `queryCacheMaxSizeInBytes` | 64 MiB | 1 GiB |

  On a large ClickHouse limit, raise the caches with it. Set a key to `""` to
  fall back to ClickHouse's own default, or set `serverConfig.enabled=false`
  to mount nothing. Changing any value restarts ClickHouse through the new
  `checksum/server-config` annotation.
- `checksum/*` pod annotations now hash only the config payload
  (`data`/`stringData`/`binaryData`, via the `purl.dataChecksum` helper), not
  the whole rendered object. Previously the hash included the
  `helm.sh/chart` label, so every chart version bump restarted ClickHouse,
  Purl and every Vector pod with nothing changed. `make helm-lint` now fails
  if a version-only bump changes any checksum.
- Upgrading to 2.1.3 restarts ClickHouse, Purl and Vector once, because the
  annotation values change format and ClickHouse gains the new mount. Later
  version-only upgrades do not.

## 2.1.2

- New `purl.trustedProxies` value (list or comma-separated string), rendered
  as `PURL_TRUSTED_PROXIES`. Default empty keeps today's behaviour: Purl uses
  the socket peer and ignores `X-Forwarded-For`. Behind an ingress or mesh,
  set it to the pod CIDR (and any external proxy) so audit logs, login
  lockout and IP rate limiting see the real client instead of the ingress pod.
  Additive; existing values files render unchanged.

## 2.1.1

- New `terminationGracePeriodSeconds` value, default **60** (was the
  Kubernetes default of 30s). On SIGTERM Purl now drains instead of killing
  its workers (#90): in-flight requests finish and every worker flushes its
  ingest buffer. The pod's grace period, not Mojo's 120s `graceful_timeout`,
  is what bounds that drain, and 30s could cut off a flush to a slow
  ClickHouse. `docker-compose.yml` sets the same 60s via `stop_grace_period`.
- New `purl.sessionMaxAge` value, rendered as `PURL_SESSION_MAX_AGE`
  (absolute dashboard session lifetime in seconds). Empty keeps the app
  default of 604800 (7 days).

Both are additive; existing values files render unchanged apart from the
grace period.

## 2.1.0

The `purl.license` values block is gone, along with the license environment
variables it rendered into the ConfigMap and Secret. Purl is MIT licensed and
every feature works without a license key. Existing values files that still
set `purl.license` render fine — the block is simply ignored — so this is a
minor bump. A license entry left in a `purl.existingSecret` Secret is ignored
too and can be deleted.

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

### 0. Credentials are no longer generated by default

**Fails if:** `clickhouse.password`, `purl.sessionSecret` or `purl.apiKeys` is
empty, `purl.existingSecret` is unset, and the release Secret does not already
hold that key.

1.x generated each of these with `randAlphaNum` and kept them stable by reading
the previous value back with `lookup`. `lookup` only reaches the cluster during
a real `helm install`/`helm upgrade`. Under `helm template`, `helm lint` and
Argo CD it returns an empty map — verified on both Helm 3.16 and Helm 4.2 — so
every render produced a **different** password, session secret and API key.
Combined with the `checksum/secret` pod annotations, each Argo CD sync rotated
the ClickHouse credentials and rolled Purl and ClickHouse: a permanently
OutOfSync app, failing database auth, every dashboard session dropped and every
agent key invalidated. See issue #22.

The chart now refuses to render rather than do that silently — but only where
the instability is real. It tells the two cases apart by whether `lookup` can
see the cluster at all. Measured on Helm v4.2.3 against a live cluster:

| Command | cluster visible to `lookup` | generation |
|---|---|---|
| `helm template`, `helm lint`, Argo CD | no | refused |
| `helm install --dry-run` (client-side) | no | refused |
| `helm install` / `helm upgrade` | **yes** | allowed |

So a plain `helm install purl purl/purl` still works with no flags, and the
generated value is written once and read back from the Secret on every later
upgrade — verified across two consecutive upgrades. What gets refused is
exactly the re-rendered population that could not converge.

`purl.autoGenerateSecrets=true` remains as an explicit override for the rare
case where you want generation in a context that cannot see the cluster. You
almost certainly do not: for GitOps, supply the credentials instead.

For GitOps, supply the credentials instead. Either point at a Secret you manage
out-of-band:

```yaml
purl:
  existingSecret: my-purl-secret
  existingSecretHasClickHousePassword: true
```

or pin all three explicitly (from SOPS, a sealed secret, an external-secrets
`ExternalSecret`, …):

```yaml
clickhouse:
  password: <from your secret store>
purl:
  sessionSecret: <from your secret store>
  apiKeys: <from your secret store>
```

Existing 1.x releases are unaffected on upgrade: the values are already in the
release Secret, so `lookup` finds them and no generation is attempted. The
guard only fires when there is genuinely nothing to reuse.

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
dashboard login and settings.json with it while every log line survived on
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

`<release>-purl-config` holds dashboard users and `settings.json`. With `config.volume.keepOnUninstall: true` (default) it is
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
and settings** unless you restore them:

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
bound and billed with no message — still holding the old logins and settings.
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

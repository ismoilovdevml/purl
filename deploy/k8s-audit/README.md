# Kubernetes API server audit → Purl

These two files configure the **kube-apiserver**, not Purl. They are static
files read by the apiserver process at startup (`--audit-policy-file`,
`--audit-webhook-config-file`) and are deliberately **not** part of the Helm
chart: the chart installs namespaced resources into a cluster, whereas these
live on the control-plane node's filesystem and are wired in via apiserver
flags. There is nothing for Helm to template.

They ship the cluster's audit trail into Purl's `POST /api/v1/k8s-audit`
endpoint (`lib/Purl/API/Controller/K8sAudit.pm`), which is what backs the
"Audit Events (24h)" / "Audit by Verb" dashboard widgets and the
`meta.source:k8s-audit` alert template.

| File | Apiserver flag |
|---|---|
| `audit-policy.yaml` | `--audit-policy-file=/etc/kubernetes/audit-policy.yaml` |
| `audit-webhook.yaml` | `--audit-webhook-config-file=/etc/kubernetes/audit-webhook.yaml` |

## Authentication — use a bearer token

`POST /api/v1/k8s-audit` sits behind the ingest auth middleware. An apiserver
audit webhook is configured with a kubeconfig, which can present a bearer token
or a client certificate but has **no way to set an arbitrary header** — so the
`X-API-Key` header every other Purl client uses is not an option here.

Purl therefore accepts a Purl **ingest API key** as
`Authorization: Bearer <key>` on the ingest routes (`POST /api/logs`,
`/api/v1/otlp/logs`, `/api/v1/syslog`, `/api/v1/k8s-audit`, `/api/_bulk`).
Same key material and same validation as `X-API-Key`; only the transport
differs. It is **not** accepted on the dashboard routes, which are
session-cookie authenticated.

Mint the key in the UI (Settings → API Keys) or set it in `PURL_API_KEYS`, then
add a `users:` block to `audit-webhook.yaml` and reference it from the context:

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: purl-audit
    cluster:
      server: http://purl.purl.svc.cluster.local:3000/api/v1/k8s-audit
users:
  - name: purl-ingest
    user:
      # A Purl ingest API key. Sent as: Authorization: Bearer <token>
      token: "REPLACE_WITH_PURL_INGEST_API_KEY"
contexts:
  - name: default
    context:
      cluster: purl-audit
      user: purl-ingest
current-context: default
```

Notes:

- The file lands at `/etc/kubernetes/audit-webhook.yaml` on the control-plane
  node with the API key in cleartext — `chmod 600`, root-owned, and treat it as
  a secret (it is not in the Helm chart precisely because it is not a
  cluster-namespaced resource).
- If a client also sends `X-API-Key`, that header wins and the bearer token is
  ignored. The apiserver never sends it, so this only matters for hand-rolled
  clients.
- The scheme name is case-insensitive (`Bearer` / `bearer`); the key itself is
  not. A malformed header (`Bearer` with no token, extra whitespace, another
  scheme) is a plain 401.
- Rotating the key means editing this file and restarting the apiserver — the
  kubeconfig is read at startup.

## Wiring it up (control-plane node, kubeadm layout)

The apiserver is a static pod, so the files must be on the host and mounted
into it. This edits the control plane — it restarts the apiserver.

```bash
scp deploy/k8s-audit/audit-policy.yaml  root@<master>:/etc/kubernetes/
scp deploy/k8s-audit/audit-webhook.yaml root@<master>:/etc/kubernetes/
```

Then in `/etc/kubernetes/manifests/kube-apiserver.yaml` add the flags and,
because `/etc/kubernetes` is already mounted in the apiserver static pod on a
kubeadm cluster, no extra volume is needed for the two files themselves — only
for the audit log path if you also enable the log backend:

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-webhook-config-file=/etc/kubernetes/audit-webhook.yaml
    - --audit-webhook-mode=batch
    - --audit-webhook-batch-max-wait=5s
```

The kubelet restarts the apiserver when the manifest changes. Verify:

```bash
kubectl -n kube-system get pod -l component=kube-apiserver
crictl logs $(crictl ps -q --name kube-apiserver) 2>&1 | tail -20
```

## Endpoint URL

`audit-webhook.yaml` points at
`http://purl.purl.svc.cluster.local:3000/api/v1/k8s-audit` — that is
`<release>.<namespace>.svc.cluster.local:<service.port>` for a chart install
named `purl` in namespace `purl` with the default `service.port: 3000`. Change
the host if your release name, namespace or service port differ.

Note the apiserver resolves this through the cluster DNS and reaches a pod
network address, so with `networkPolicy.enabled=true` the control-plane node
IP must be allowed in `networkPolicy.ingress.fromCIDRs`.

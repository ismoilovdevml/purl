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

## KNOWN GAP — the webhook cannot authenticate today

`POST /api/v1/k8s-audit` sits behind the ingest auth middleware, and
`Purl::API::Middleware::Auth::_check_api_key` reads the key from the
**`X-API-Key`** header only. An apiserver audit webhook is configured with a
kubeconfig, which can present a bearer token or a client certificate — it has
no way to set an arbitrary header. So with `purl.authEnabled=true` (the
default) every audit event is rejected with 401.

`audit-webhook.yaml` therefore ships with no `users:` block: adding a `token:`
would not help until the app accepts `Authorization: Bearer`. Until then this
path only works against an install with ingest auth disabled, which is not a
configuration to run on a real cluster.

Tracked as a backend follow-up: accept `Authorization: Bearer <key>` as an
alternative to `X-API-Key` on the ingest routes.

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

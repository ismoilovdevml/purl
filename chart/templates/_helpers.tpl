{{/*
Expand the name of the chart.
*/}}
{{- define "purl.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
If release name contains chart name it will be used as a full name.
*/}}
{{- define "purl.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "purl.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "purl.labels" -}}
helm.sh/chart: {{ include "purl.chart" . }}
{{ include "purl.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "purl.selectorLabels" -}}
app.kubernetes.io/name: {{ include "purl.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "purl.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "purl.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
ClickHouse fully qualified name
*/}}
{{- define "purl.clickhouse.fullname" -}}
{{- printf "%s-clickhouse" (include "purl.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
ClickHouse labels
*/}}
{{- define "purl.clickhouse.labels" -}}
helm.sh/chart: {{ include "purl.chart" . }}
{{ include "purl.clickhouse.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
ClickHouse selector labels
*/}}
{{- define "purl.clickhouse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "purl.name" . }}-clickhouse
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: clickhouse
{{- end }}

{{/*
Backup pod selector labels.

Deliberately NOT purl.selectorLabels: the backup pods used to carry them,
which made every CronJob pod count towards the Purl PodDisruptionBudget and
put the pods under the Purl NetworkPolicy (whose egress does not allow the
ClickHouse native port the backup actually uses).
*/}}
{{- define "purl.backup.selectorLabels" -}}
app.kubernetes.io/name: {{ include "purl.name" . }}-backup
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backup
{{- end }}

{{/*
Backup labels
*/}}
{{- define "purl.backup.labels" -}}
helm.sh/chart: {{ include "purl.chart" . }}
{{ include "purl.backup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Base S3 URL for backups (bucket + optional custom endpoint), without the
object key. Shared by the CronJob script and the ClickHouse <s3> credentials
block so both match on the same endpoint prefix.
*/}}
{{- define "purl.backup.s3BaseUrl" -}}
{{- if .Values.backup.s3.endpoint }}
{{- printf "%s/%s" (trimSuffix "/" .Values.backup.s3.endpoint) .Values.backup.s3.bucket }}
{{- else }}
{{- printf "https://%s.s3.%s.amazonaws.com" .Values.backup.s3.bucket .Values.backup.s3.region }}
{{- end }}
{{- end }}

{{/*
Resolve the ClickHouse host.
If the built-in ClickHouse is enabled, use the internal service name.
Otherwise, use the user-provided external host.
*/}}
{{- define "purl.clickhouse.host" -}}
{{- if .Values.clickhouse.enabled }}
{{- include "purl.clickhouse.fullname" . }}
{{- else }}
{{- required "clickhouse.host is required when clickhouse.enabled=false" .Values.clickhouse.host }}
{{- end }}
{{- end }}

{{/*
Name of the Secret holding Purl's runtime secrets.
Either the chart-managed one or purl.existingSecret when the operator brings
their own (so nothing sensitive has to pass through values / release history).
*/}}
{{- define "purl.secretName" -}}
{{- default (include "purl.fullname" .) .Values.purl.existingSecret }}
{{- end }}

{{/*
Data of the existing release Secret, normalised to a dict.

A clusterless `lookup` (helm lint / helm template / Argo CD) returns an EMPTY
MAP on both Helm 3.16 and Helm 4.2 — verified, not nil as an earlier comment
here claimed. Either way `.data` on it is nil, and Go template `and` evaluates
every argument (no short-circuit), so `and $s (index $s.data "K")` still runs
the index and dies with "index of untyped nil". Normalise once, index that.
*/}}
{{- define "purl.existingSecretData" -}}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "purl.fullname" .)) }}
{{- default dict (default dict $existing).data | toJson }}
{{- end }}

{{/*
Refuse to invent a credential that has to stay stable (issue #22).

Generation only converges when `lookup` can read the cluster: a real
`helm install` writes the random value once, and every later `helm upgrade`
reads it back out of the release Secret. `helm template` and Argo CD render
WITHOUT cluster access, so the lookup is always empty and every render mints a
NEW value. Because deployment.yaml and clickhouse-statefulset.yaml carry
checksum/secret annotations, each sync also rolls both workloads — so the
symptom is a permanently OutOfSync app that restart-loops while ClickHouse
auth fails, all dashboard sessions drop and every agent API key stops working.

Silently unstable is the worst outcome, so this fails the render instead —
BUT only where the instability is real. Refusing everywhere would break the
documented quickstart, because a FIRST `helm install` also finds an empty
lookup (there is no Secret yet), and that install is perfectly stable: the
value is written once and every later upgrade reads it back.

The two cases are told apart by whether `lookup` can see the cluster at all.
Measured on Helm v4.2.3 against a real cluster, probing kube-system:

  helm template                 -> cluster NOT visible
  helm install --dry-run        -> cluster NOT visible
  helm install --dry-run=server -> cluster visible
  helm install (real)           -> cluster visible
  helm upgrade --dry-run=server -> cluster visible

So "cluster not visible" is exactly the re-rendered population (helm template,
helm lint, Argo CD) and never a real install. A client-side `--dry-run` is
caught too; that is correct rather than unfortunate, since a client dry-run
cannot show the real generated value anyway.

If the probe is ever wrong in the permissive direction we are no worse off
than chart 1.x; wrong in the strict direction and an install fails loudly with
the message below. Neither failure mode is silent.

Usage:
  {{- include "purl.assertGeneratedSecretAllowed"
        (dict "root" . "key" "PURL_CLICKHOUSE_PASSWORD" "setting" "clickhouse.password") }}
*/}}
{{- define "purl.clusterVisible" -}}
{{- if (lookup "v1" "Namespace" "" "kube-system") }}true{{ end }}
{{- end }}

{{- define "purl.assertGeneratedSecretAllowed" -}}
{{- if and (not .root.Values.purl.autoGenerateSecrets) (not (include "purl.clusterVisible" .root)) }}
{{- fail (printf (join "\n" (list
  ""
  "purl: refusing to generate %s."
  ""
  "%s is empty and the Secret %q in namespace %q does not already contain %s,"
  "so the chart would have to invent one. A generated value is only stable when"
  "`lookup` can see the cluster; `helm template` and Argo CD render without it,"
  "so every render would produce a DIFFERENT %s (issue #22)."
  ""
  "Choose one:"
  "  GitOps / helm template / anything re-rendered:"
  "    - set purl.existingSecret to a Secret you manage out-of-band, or"
  "    - set %s explicitly (e.g. from a sealed secret or SOPS)."
  "  Interactive `helm install` against a live cluster:"
  "    - --set purl.autoGenerateSecrets=true"
  ""))
  .key .setting (include "purl.fullname" .root) .root.Release.Namespace .key .key .setting) }}
{{- end }}
{{- end }}

{{/*
Resolve the ClickHouse application password.

Empty clickhouse.password must NOT mean "no password": that created a
passwordless user reachable from ::/0. Resolution order:
  1. explicit .Values.clickhouse.password
  2. the value already stored in the release Secret (so upgrades keep it —
     rotating it silently would lock Purl out of its own database)
  3. a fresh random 32-char password, but ONLY with purl.autoGenerateSecrets;
     otherwise the render fails — see purl.assertGeneratedSecretAllowed.
Returns "" when purl.existingSecret is set: the operator supplies
PURL_CLICKHOUSE_PASSWORD themselves and the chart must not invent one.
*/}}
{{- define "purl.clickhouse.password" -}}
{{- if .Values.purl.existingSecret }}
{{- "" }}
{{- else if .Values.clickhouse.password }}
{{- .Values.clickhouse.password }}
{{- else }}
{{- $existingData := (include "purl.existingSecretData" . | fromJson) }}
{{- if index $existingData "PURL_CLICKHOUSE_PASSWORD" }}
{{- index $existingData "PURL_CLICKHOUSE_PASSWORD" | b64dec }}
{{- else }}
{{- include "purl.assertGeneratedSecretAllowed" (dict "root" . "key" "PURL_CLICKHOUSE_PASSWORD" "setting" "clickhouse.password") }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Effective number of Purl replicas, honouring autoscaling.
*/}}
{{- define "purl.replicaCount" -}}
{{- if .Values.autoscaling.enabled }}
{{- .Values.autoscaling.minReplicas }}
{{- else }}
{{- .Values.replicaCount }}
{{- end }}
{{- end }}

{{/*
Purl image reference
*/}}
{{- define "purl.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

{{/*
Checksum of a rendered config object's PAYLOAD for a checksum/* pod annotation.

Hashes only data / stringData / binaryData. Hashing the whole rendered file
(the old `include ... | sha256sum`) also hashed metadata.labels, which carry
helm.sh/chart=purl-<chart version> — so every chart version bump rolled
ClickHouse, Purl and the Vector DaemonSet even when no configuration or
credential had changed. Every template passed here must render a single
document (or nothing).

Usage: {{ include "purl.dataChecksum" (dict "ctx" $ "file" "secret.yaml") }}
*/}}
{{- define "purl.dataChecksum" -}}
{{- $obj := include (print .ctx.Template.BasePath "/" .file) .ctx | fromYaml | default dict -}}
{{- pick $obj "data" "stringData" "binaryData" | toYaml | sha256sum -}}
{{- end }}

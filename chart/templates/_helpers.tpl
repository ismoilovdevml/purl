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
Resolve the ClickHouse application password.

Empty clickhouse.password must NOT mean "no password": that created a
passwordless user reachable from ::/0. Resolution order:
  1. explicit .Values.clickhouse.password
  2. the value already stored in the release Secret (so upgrades keep it —
     rotating it silently would lock Purl out of its own database)
  3. a fresh random 32-char password
Returns "" when purl.existingSecret is set: the operator supplies
PURL_CLICKHOUSE_PASSWORD themselves and the chart must not invent one.
*/}}
{{- define "purl.clickhouse.password" -}}
{{- if .Values.purl.existingSecret }}
{{- "" }}
{{- else if .Values.clickhouse.password }}
{{- .Values.clickhouse.password }}
{{- else }}
{{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "purl.fullname" .)) }}
{{- if and $existing (index $existing.data "PURL_CLICKHOUSE_PASSWORD") }}
{{- index $existing.data "PURL_CLICKHOUSE_PASSWORD" | b64dec }}
{{- else }}
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

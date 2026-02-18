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
Purl image reference
*/}}
{{- define "purl.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}

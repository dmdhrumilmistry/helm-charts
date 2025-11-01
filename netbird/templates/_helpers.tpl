{{/*
Expand the name of the chart.
This template expects the root context as .
*/}}
{{- define "netbird.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
This template expects the root context as .
*/}}
{{- define "netbird.fullname" -}}
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
This template expects the root context as .
*/}}
{{- define "netbird.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
This template now uses $ to be safe and can be called from any context.
*/}}
{{- define "netbird.labels" -}}
helm.sh/chart: {{ include "netbird.chart" $ }}
{{ include "netbird.selectorLabels" $ }}
{{- if $.Chart.AppVersion }}
app.kubernetes.io/version: {{ $.Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ $.Release.Service }}
{{- end }}

{{/*
Selector labels
This template now uses $ to be safe and can be called from any context.
*/}}
{{- define "netbird.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" $ }}
app.kubernetes.io/instance: {{ $.Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
This template now uses $ to be safe and can be called from any context.
*/}}
{{- define "netbird.serviceAccountName" -}}
{{- if $.Values.serviceAccount.create }}
{{- default (include "netbird.fullname" $) $.Values.serviceAccount.name }}
{{- else }}
{{- default "default" $.Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Signal component selector labels
*/}}
{{- define "netbird.signal.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "signal"
{{- end }}

{{/*
Management component selector labels
*/}}
{{- define "netbird.management.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "management"
{{- end }}

{{/*
Dashboard component selector labels
*/}}
{{- define "netbird.dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "dashboard"
{{- end }}

{{/*
Coturn component selector labels
*/}}
{{- define "netbird.coturn.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "coturn"
{{- end }}

{{/*
Relay component selector labels
*/}}
{{- define "netbird.relay.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "relay"
{{- end }}

{{/*
Postgres component selector labels
*/}}
{{- define "netbird.postgres.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: "postgres"
{{- end }}
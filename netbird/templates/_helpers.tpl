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

{{/*
PostgreSQL hostname - automatically constructed from service name
*/}}
{{- define "netbird.postgres.hostname" -}}
{{- if .Values.postgres.enabled -}}
{{- printf "%s-postgres" (include "netbird.fullname" .) -}}
{{- else -}}
{{- .Values.postgres.externalHost | default "localhost" -}}
{{- end -}}
{{- end }}


{{/*
PostgreSQL connection URL - using actual values from secrets
*/}}
{{- define "netbird.postgres.url" -}}
{{- $host := include "netbird.postgres.hostname" . -}}
{{- $port := .Values.postgres.service.port | default 5432 -}}
{{- $dbname := .Values.postgres.database | default "netbird" -}}
{{- $username := .Values.secrets.POSTGRES_USER | default (.Values.postgres.auth.username | default "netbird") -}}
{{- $password := .Values.secrets.POSTGRES_PASSWORD | default (.Values.postgres.auth.password | default "defaultpass") -}}
{{- printf "postgres://%s:%s@%s:%v/%s?sslmode=disable" $username $password $host $port $dbname -}}
{{- end }}

{{/*
Secret name for all components
*/}}
{{- define "netbird.secretName" -}}
{{ include "netbird.fullname" . }}-secrets
{{- end }}

{{/*
Component selector labels
This template expects the component name as . and uses $ for root context
Usage: include "netbird.component.selectorLabels" "signal"
*/}}
{{- define "netbird.component.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" $ }}
app.kubernetes.io/instance: {{ $.Release.Name }}
app.kubernetes.io/component: {{ . | quote }}
{{- end }}
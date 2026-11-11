{{/*
Expand the name of the chart.
*/}}
{{- define "nandi.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nandi.fullname" -}}
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

{{- define "nandi.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nandi.labels" -}}
helm.sh/chart: {{ include "nandi.chart" . }}
{{ include "nandi.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: nandi
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "nandi.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nandi.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Object names. The proxy and admin Services get short, predictable names so
agents can be pointed at http://<release>-proxy.<namespace>:8787.
*/}}
{{- define "nandi.proxyServiceName" -}}
{{- printf "%s-proxy" (include "nandi.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nandi.adminServiceName" -}}
{{- printf "%s-admin" (include "nandi.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nandi.headlessServiceName" -}}
{{- printf "%s-headless" (include "nandi.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nandi.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "nandi.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "nandi.image" -}}
{{- printf "%s:%s" .Values.image.repository (default .Chart.AppVersion .Values.image.tag) }}
{{- end }}

{{/*
Admin token Secret: an existing Secret, or one the chart manages.
*/}}
{{- define "nandi.adminSecretName" -}}
{{- if .Values.admin.existingSecret }}
{{- .Values.admin.existingSecret }}
{{- else }}
{{- printf "%s-admin" (include "nandi.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "nandi.adminSecretKey" -}}
{{- if .Values.admin.existingSecret }}{{ .Values.admin.existingSecretKey }}{{ else }}token{{ end }}
{{- end }}

{{/*
The admin token: from values, else the one already in the cluster (so
upgrades keep it), else a new random one.
*/}}
{{- define "nandi.adminToken" -}}
{{- if .Values.admin.token }}
{{- .Values.admin.token }}
{{- else }}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "nandi.adminSecretName" .) }}
{{- if and $existing $existing.data (index $existing.data "token") }}
{{- index $existing.data "token" | b64dec }}
{{- else }}
{{- randAlphaNum 40 }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nandi.envSecretName" -}}
{{- printf "%s-env" (include "nandi.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
The rendered nandi.yaml: .Values.config with the keys the chart owns set
on top. Listeners bind all interfaces inside the pod, state lives on the
volume, the admin token comes from the Secret, and policy files are the
ones mounted from the ConfigMap.
*/}}
{{- define "nandi.config" -}}
{{- $cfg := deepCopy (default dict .Values.config) }}
{{- $listen := deepCopy (default dict $cfg.listen) }}
{{- $_ := set $listen "proxy" (printf "0.0.0.0:%d" (int .Values.containerPorts.proxy)) }}
{{- $_ := set $cfg "listen" $listen }}
{{- $admin := deepCopy (default dict $cfg.admin) }}
{{- $_ := set $admin "listen" (printf "0.0.0.0:%d" (int .Values.containerPorts.admin)) }}
{{- $_ := set $admin "token" "env:NANDI_ADMIN_TOKEN" }}
{{- $_ := set $admin "ui" .Values.admin.ui }}
{{- $_ := set $cfg "admin" $admin }}
{{- $_ := set $cfg "data_dir" "/var/lib/nandi" }}
{{- $policy := deepCopy (default dict $cfg.policy) }}
{{- $rules := list }}
{{- if .Values.policies.rules }}{{ $rules = append $rules "/etc/nandi/policies/rules.yaml" }}{{ end }}
{{- $cedar := list }}
{{- if .Values.policies.cedar }}{{ $cedar = append $cedar "/etc/nandi/policies/policy.cedar" }}{{ end }}
{{- range $name, $_ := .Values.policies.extraFiles }}
{{- if hasSuffix ".cedar" $name }}{{ $cedar = append $cedar (printf "/etc/nandi/policies/%s" $name) }}
{{- else if or (hasSuffix ".yaml" $name) (hasSuffix ".yml" $name) }}{{ $rules = append $rules (printf "/etc/nandi/policies/%s" $name) }}{{ end }}
{{- end }}
{{- $_ := set $policy "rules" $rules }}
{{- $_ := set $policy "cedar" $cedar }}
{{- $_ := set $cfg "policy" $policy }}
{{- toYaml $cfg }}
{{- end }}

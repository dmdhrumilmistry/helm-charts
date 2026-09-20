{{/*
Expand the name of the chart.
*/}}
{{- define "teleport.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.fullname" -}}
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

{{- define "teleport.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.labels" -}}
helm.sh/chart: {{ include "teleport.chart" . }}
{{ include "teleport.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: teleport
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "teleport.selectorLabels" -}}
app.kubernetes.io/name: {{ include "teleport.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component labels.
Usage: include "teleport.componentLabels" (dict "root" $ "component" "proxy")
*/}}
{{- define "teleport.componentLabels" -}}
{{ include "teleport.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "teleport.componentSelectorLabels" -}}
{{ include "teleport.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
=====================================================================
Object names
=====================================================================
*/}}
{{- define "teleport.auth.fullname" -}}
{{- printf "%s-auth" (include "teleport.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.proxy.fullname" -}}
{{- printf "%s-proxy" (include "teleport.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.agent.fullname" -}}
{{- printf "%s-agent" (include "teleport.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "teleport.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "teleport.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "teleport.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "teleport.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "teleport.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Cluster identity
=====================================================================
*/}}
{{- define "teleport.clusterName" -}}
{{- required "clusterName is required: set it to the public FQDN Teleport is reached at, e.g. --set clusterName=teleport.example.com" .Values.clusterName -}}
{{- end }}

{{/*
Public address peers and browsers connect to, always with an explicit port.
*/}}
{{- define "teleport.publicAddr" -}}
{{- printf "%s:%v" (include "teleport.clusterName" .) .Values.proxy.service.port -}}
{{- end }}

{{- define "teleport.mode" -}}
{{- $m := .Values.mode | default "standalone" -}}
{{- if not (has $m (list "standalone" "ha")) -}}
{{- fail (printf "mode must be \"standalone\" or \"ha\", got %q" $m) -}}
{{- end -}}
{{- $m -}}
{{- end }}

{{- define "teleport.isHA" -}}
{{- if eq (include "teleport.mode" .) "ha" -}}true{{- end -}}
{{- end }}

{{/*
In-cluster address the Proxy and agents use to reach the Auth Service.
*/}}
{{- define "teleport.authServerAddr" -}}
{{- printf "%s.%s.svc.%s:3025" (include "teleport.auth.fullname" .) .Release.Namespace .Values.global.clusterDomain -}}
{{- end }}

{{/*
=====================================================================
Generated secrets

Generated once, then read back from the live cluster on upgrade so that
re-running helm never rotates the join token and locks agents out.
=====================================================================
*/}}
{{- define "teleport.generatedSecrets" -}}
{{- if not (hasKey .Values "_tpGenerated") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "teleport.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $existing -}}{{- $old = $existing.data -}}{{- end -}}
  {{- $gen := dict -}}
  {{- $fresh := dict
        "joinToken"        (randAlphaNum 32 | lower)
        "postgresPassword" (randAlphaNum 24)
  -}}
  {{- range $key, $new := $fresh -}}
    {{- $explicit := index $.Values.secrets $key -}}
    {{- if $explicit -}}
      {{- $_ := set $gen $key $explicit -}}
    {{- else if (index $old $key) -}}
      {{- $_ := set $gen $key (index $old $key | b64dec) -}}
    {{- else -}}
      {{- $_ := set $gen $key $new -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $.Values "_tpGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "teleport.gen" -}}
{{- include "teleport.generatedSecrets" .root -}}
{{- index .root.Values._tpGenerated .key -}}
{{- end }}

{{/*
=====================================================================
Database (HA mode only)
=====================================================================
*/}}
{{- define "teleport.postgresql.host" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s.%s.svc.%s" (include "teleport.postgresql.fullname" .) .Release.Namespace .Values.global.clusterDomain -}}
{{- else -}}
{{- required "externalDatabase.host is required in ha mode when postgresql.enabled is false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end }}

{{- define "teleport.postgresql.port" -}}
{{- if .Values.postgresql.enabled -}}{{- .Values.postgresql.service.port -}}{{- else -}}{{- .Values.externalDatabase.port -}}{{- end -}}
{{- end }}

{{- define "teleport.postgresql.username" -}}
{{- if .Values.postgresql.enabled -}}{{- .Values.postgresql.auth.username -}}{{- else -}}{{- .Values.externalDatabase.username -}}{{- end -}}
{{- end }}

{{- define "teleport.postgresql.password" -}}
{{- if .Values.postgresql.enabled -}}
{{- include "teleport.gen" (dict "root" . "key" "postgresPassword") -}}
{{- else -}}
{{- required "externalDatabase.password is required in ha mode when postgresql.enabled is false" .Values.externalDatabase.password -}}
{{- end -}}
{{- end }}

{{- define "teleport.postgresql.sslmode" -}}
{{- if .Values.postgresql.enabled -}}disable{{- else -}}{{- .Values.externalDatabase.sslmode -}}{{- end -}}
{{- end }}

{{/*
libpq connection URI. Teleport parses these as URIs, not key=value pairs,
and the audit_events_uri field accepts nothing else.
Usage: include "teleport.postgresql.uri" (dict "root" $ "database" "teleport_backend" "extra" "&pool_max_conns=20")
*/}}
{{- define "teleport.postgresql.uri" -}}
{{- $r := .root -}}
{{- printf "postgresql://%s:%s@%s:%v/%s?sslmode=%s%s"
      (include "teleport.postgresql.username" $r)
      (include "teleport.postgresql.password" $r | urlquery)
      (include "teleport.postgresql.host" $r)
      (include "teleport.postgresql.port" $r)
      .database
      (include "teleport.postgresql.sslmode" $r)
      (.extra | default "") -}}
{{- end }}

{{/*
=====================================================================
Images
=====================================================================
*/}}
{{- define "teleport.image" -}}
{{- $registry := .image.registry | default .root.Values.global.imageRegistry -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "teleport.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Do any agent services need to run at all?
*/}}
{{- define "teleport.agentsEnabled" -}}
{{- if or .Values.kubernetesAccess.enabled .Values.apps .Values.databases -}}true{{- end -}}
{{- end }}

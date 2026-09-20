{{/*
Expand the name of the chart.
*/}}
{{- define "netbird.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
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

{{- define "netbird.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to every object.
*/}}
{{- define "netbird.labels" -}}
helm.sh/chart: {{ include "netbird.chart" . }}
{{ include "netbird.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: netbird
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "netbird.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component labels.
Usage: include "netbird.componentLabels" (dict "root" $ "component" "server")
*/}}
{{- define "netbird.componentLabels" -}}
{{ include "netbird.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "netbird.componentSelectorLabels" -}}
{{ include "netbird.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
=====================================================================
Object names
=====================================================================
*/}}
{{- define "netbird.server.fullname" -}}
{{- printf "%s-server" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.dashboard.fullname" -}}
{{- printf "%s-dashboard" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "netbird.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "netbird.server.configSecretName" -}}
{{- printf "%s-config" (include "netbird.server.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "netbird.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "netbird.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Domain / URL helpers
=====================================================================
*/}}
{{- define "netbird.domain" -}}
{{- required "global.domain is required: set it to the public FQDN NetBird will be reached at, e.g. --set global.domain=netbird.example.com" .Values.global.domain -}}
{{- end }}

{{- define "netbird.scheme" -}}
{{- if .Values.global.tls -}}https{{- else -}}http{{- end -}}
{{- end }}

{{/*
Public port NetBird is reached on. Defaults to 443/80 depending on TLS.
*/}}
{{- define "netbird.publicPort" -}}
{{- if .Values.global.port -}}
{{- .Values.global.port -}}
{{- else if .Values.global.tls -}}443
{{- else -}}80
{{- end -}}
{{- end }}

{{/*
Public base URL, port omitted when it is the scheme default.
*/}}
{{- define "netbird.publicURL" -}}
{{- $scheme := include "netbird.scheme" . -}}
{{- $port := include "netbird.publicPort" . -}}
{{- if or (and (eq $scheme "https") (eq $port "443")) (and (eq $scheme "http") (eq $port "80")) -}}
{{- printf "%s://%s" $scheme (include "netbird.domain" .) -}}
{{- else -}}
{{- printf "%s://%s:%s" $scheme (include "netbird.domain" .) $port -}}
{{- end -}}
{{- end }}

{{/*
server.exposedAddress always carries an explicit port (upstream format).
*/}}
{{- define "netbird.exposedAddress" -}}
{{- printf "%s://%s:%s" (include "netbird.scheme" .) (include "netbird.domain" .) (include "netbird.publicPort" .) -}}
{{- end }}

{{/*
=====================================================================
Generated secrets

Generated once per render, then reused from the live cluster on upgrade so
that re-running helm never silently rotates a key and orphans stored data.
Precedence: explicit value > value already in the cluster > freshly generated.
=====================================================================
*/}}
{{- define "netbird.generatedSecrets" -}}
{{- if not (hasKey .Values "_nbGenerated") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "netbird.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $existing -}}{{- $old = $existing.data -}}{{- end -}}
  {{- $gen := dict -}}
  {{- $fresh := dict
        "authSecret"                 (randAlphaNum 40)
        "storeEncryptionKey"         (randAlphaNum 32 | b64enc)
        "sessionCookieEncryptionKey" (randAlphaNum 32)
        "postgresPassword"           (randAlphaNum 24)
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
  {{- $_ := set $.Values "_nbGenerated" $gen -}}
{{- end -}}
{{- end }}

{{/*
Usage: include "netbird.gen" (dict "root" $ "key" "authSecret")
*/}}
{{- define "netbird.gen" -}}
{{- include "netbird.generatedSecrets" .root -}}
{{- index .root.Values._nbGenerated .key -}}
{{- end }}

{{/*
=====================================================================
Database
=====================================================================
*/}}
{{- define "netbird.postgresql.host" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s.%s.svc.%s" (include "netbird.postgresql.fullname" .) .Release.Namespace .Values.global.clusterDomain -}}
{{- else -}}
{{- required "externalDatabase.host is required when postgresql.enabled is false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end }}

{{- define "netbird.postgresql.port" -}}
{{- if .Values.postgresql.enabled -}}{{- .Values.postgresql.service.port -}}{{- else -}}{{- .Values.externalDatabase.port -}}{{- end -}}
{{- end }}

{{- define "netbird.postgresql.username" -}}
{{- if .Values.postgresql.enabled -}}{{- .Values.postgresql.auth.username -}}{{- else -}}{{- .Values.externalDatabase.username -}}{{- end -}}
{{- end }}

{{- define "netbird.postgresql.database" -}}
{{- if .Values.postgresql.enabled -}}{{- .Values.postgresql.auth.database -}}{{- else -}}{{- .Values.externalDatabase.database -}}{{- end -}}
{{- end }}

{{- define "netbird.postgresql.sslmode" -}}
{{- if .Values.postgresql.enabled -}}disable{{- else -}}{{- .Values.externalDatabase.sslmode -}}{{- end -}}
{{- end }}

{{- define "netbird.postgresql.password" -}}
{{- if .Values.postgresql.enabled -}}
{{- include "netbird.gen" (dict "root" . "key" "postgresPassword") -}}
{{- else -}}
{{- required "externalDatabase.password is required when postgresql.enabled is false" .Values.externalDatabase.password -}}
{{- end -}}
{{- end }}

{{/*
Key-value DSN, the format NetBird (GORM/pgx) expects.
Usage: include "netbird.postgresql.dsn" (dict "root" $ "database" "netbird")
*/}}
{{- define "netbird.postgresql.dsn" -}}
{{- $r := .root -}}
{{- printf "host=%s port=%v user=%s password=%s dbname=%s sslmode=%s" (include "netbird.postgresql.host" $r) (include "netbird.postgresql.port" $r) (include "netbird.postgresql.username" $r) (include "netbird.postgresql.password" $r) .database (include "netbird.postgresql.sslmode" $r) -}}
{{- end }}

{{/*
Whether NetBird should store its data in PostgreSQL rather than SQLite.
*/}}
{{- define "netbird.postgresql.inUse" -}}
{{- if or .Values.postgresql.enabled .Values.externalDatabase.host -}}true{{- end -}}
{{- end }}

{{/*
=====================================================================
Ingress annotation presets

ingress.controller picks sensible defaults so a stock install needs no
annotation wrangling. User-supplied annotations always take precedence.
=====================================================================
*/}}
{{- define "netbird.ingress.baseAnnotations" -}}
{{- $a := dict -}}
{{- if eq .Values.ingress.controller "nginx" -}}
  {{- $_ := set $a "nginx.ingress.kubernetes.io/proxy-body-size" "0" -}}
  {{- $_ := set $a "nginx.ingress.kubernetes.io/proxy-read-timeout" "3600" -}}
  {{- $_ := set $a "nginx.ingress.kubernetes.io/proxy-send-timeout" "3600" -}}
{{- end -}}
{{- toYaml $a -}}
{{- end }}

{{/*
cert-manager is wired to the HTTP Ingress only. Two Ingresses pointing a
cert-manager annotation at one Secret would race to own the same
Certificate, so the gRPC Ingress reuses the Secret the HTTP one requests.
*/}}
{{- define "netbird.ingress.httpAnnotations" -}}
{{- $base := fromYaml (include "netbird.ingress.baseAnnotations" .) -}}
{{- if and .Values.ingress.tls.enabled .Values.ingress.tls.clusterIssuer -}}
  {{- $_ := set $base "cert-manager.io/cluster-issuer" .Values.ingress.tls.clusterIssuer -}}
{{- end -}}
{{- $merged := merge (deepCopy .Values.ingress.annotations) $base -}}
{{- if $merged }}{{ toYaml $merged }}{{ end -}}
{{- end }}

{{- define "netbird.ingress.grpcAnnotations" -}}
{{- $base := fromYaml (include "netbird.ingress.baseAnnotations" .) -}}
{{- if eq .Values.ingress.controller "nginx" -}}
  {{- $_ := set $base "nginx.ingress.kubernetes.io/backend-protocol" "GRPC" -}}
{{- end -}}
{{- if and .Values.ingress.tls.enabled .Values.ingress.tls.clusterIssuer .Values.ingress.tls.grpcSecretName -}}
  {{- $_ := set $base "cert-manager.io/cluster-issuer" .Values.ingress.tls.clusterIssuer -}}
{{- end -}}
{{- $merged := merge (deepCopy .Values.ingress.grpcAnnotations) (deepCopy .Values.ingress.annotations) $base -}}
{{- if $merged }}{{ toYaml $merged }}{{ end -}}
{{- end }}

{{/*
Traefik picks the backend scheme from a Service annotation, not the Ingress.
*/}}
{{- define "netbird.server.grpcServiceAnnotations" -}}
{{- $a := dict -}}
{{- if eq .Values.ingress.controller "traefik" -}}
  {{- $_ := set $a "traefik.ingress.kubernetes.io/service.serversscheme" "h2c" -}}
{{- end -}}
{{- $merged := merge (deepCopy .Values.server.grpcService.annotations) $a -}}
{{- if $merged }}{{ toYaml $merged }}{{ end -}}
{{- end }}

{{/*
=====================================================================
Images
=====================================================================
Usage: include "netbird.image" (dict "root" $ "image" .Values.x.image "defaultTag" $tag)
*/}}
{{- define "netbird.image" -}}
{{- $registry := .image.registry | default .root.Values.global.imageRegistry -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "netbird.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

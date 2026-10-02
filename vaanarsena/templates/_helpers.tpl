{{- define "vs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vs.fullname" -}}
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

{{- define "vs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vs.labels" -}}
helm.sh/chart: {{ include "vs.chart" . }}
{{ include "vs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: vaanarsena
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "vs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "vs.secretName" -}}
{{- .Values.existingSecret | default (printf "%s-secrets" (include "vs.fullname" .)) -}}
{{- end }}

{{/* Secret with ca.crt only: safe to hand to the ingress controller. */}}
{{- define "vs.caCertSecret" -}}
{{- .Values.ca.existingSecret | default (printf "%s-ca" (include "vs.fullname" .)) -}}
{{- end }}

{{/* Secret with the CA key: mounted only into the server. */}}
{{- define "vs.caKeySecret" -}}
{{- .Values.ca.existingSecret | default (printf "%s-ca-key" (include "vs.fullname" .)) -}}
{{- end }}

{{/* Ingress controller flavour: nginx, traefik or other. */}}
{{- define "vs.ingressController" -}}
{{- $c := .Values.ingress.controller | default "nginx" -}}
{{- if not (has $c (list "nginx" "traefik" "other")) -}}
{{- fail "ingress.controller must be nginx, traefik or other" -}}
{{- end -}}
{{- $c -}}
{{- end }}

{{/* Header the ingress forwards the client certificate in. */}}
{{- define "vs.clientCertHeader" -}}
{{- if eq (include "vs.ingressController" .) "traefik" -}}X-Forwarded-Tls-Client-Cert{{- else -}}ssl-client-cert{{- end -}}
{{- end }}

{{/* Namespace the ingress controller pods run in, for the NetworkPolicy. */}}
{{- define "vs.ingressNamespace" -}}
{{- if .Values.networkPolicy.ingressNamespace -}}
{{- .Values.networkPolicy.ingressNamespace -}}
{{- else if eq (include "vs.ingressController" .) "traefik" -}}
kube-system
{{- else -}}
ingress-nginx
{{- end -}}
{{- end }}

{{- define "vs.manifestsConfigMap" -}}
{{- .Values.manifests.existingConfigMap | default (printf "%s-manifests" (include "vs.fullname" .)) -}}
{{- end }}

{{- define "vs.manifestsEnabled" -}}
{{- if or .Values.manifests.files .Values.manifests.existingConfigMap }}true{{ end -}}
{{- end }}

{{- define "vs.postgresName" -}}
{{- printf "%s-postgresql" (include "vs.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "vs.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "vs.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{- define "vs.publicUrl" -}}
{{- if .Values.publicUrl -}}
{{- .Values.publicUrl | trimSuffix "/" -}}
{{- else -}}
{{- printf "https://%s" (required "publicHost is required, e.g. --set publicHost=mdm.example.com" .Values.publicHost) -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Generated material

Created on first install, then read back from the live cluster on every
upgrade so it never changes: a new secret key would make the stored data
unreadable, and a new CA would orphan every enrolled device.
=====================================================================
*/}}
{{- define "vs.generated" -}}
{{- if not (hasKey .Values "_vsGenerated") -}}
  {{- $gen := dict -}}
  {{- $app := (lookup "v1" "Secret" .Release.Namespace (include "vs.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $app -}}{{- $old = $app.data -}}{{- end -}}
  {{- range $key, $explicit := dict "secretKey" $.Values.secretKey "adminPassword" $.Values.admin.password "postgresPassword" $.Values.postgresql.password -}}
    {{- if $explicit -}}
      {{- $_ := set $gen $key $explicit -}}
    {{- else if (index $old $key) -}}
      {{- $_ := set $gen $key (index $old $key | b64dec) -}}
    {{- else if eq $key "secretKey" -}}
      {{- $_ := set $gen $key (randAlphaNum 64) -}}
    {{- else -}}
      {{- $_ := set $gen $key (randAlphaNum 24) -}}
    {{- end -}}
  {{- end -}}
  {{- $crt := (lookup "v1" "Secret" .Release.Namespace (include "vs.caCertSecret" .)) -}}
  {{- $key := (lookup "v1" "Secret" .Release.Namespace (include "vs.caKeySecret" .)) -}}
  {{- if and $crt $key (index $crt.data "ca.crt") (index $key.data "ca.key") -}}
    {{- $_ := set $gen "caCert" (index $crt.data "ca.crt" | b64dec) -}}
    {{- $_ := set $gen "caKey" (index $key.data "ca.key" | b64dec) -}}
  {{- else -}}
    {{- $ca := genCA (printf "%s MDM CA" .Values.orgName) (int .Values.ca.validityDays) -}}
    {{- $_ := set $gen "caCert" $ca.Cert -}}
    {{- $_ := set $gen "caKey" $ca.Key -}}
  {{- end -}}
  {{- $_ := set $.Values "_vsGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "vs.gen" -}}
{{- include "vs.generated" .root -}}
{{- index .root.Values._vsGenerated .key -}}
{{- end }}

{{- define "vs.databaseUrl" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "postgres://%s:%s@%s:5432/%s?sslmode=disable" .Values.postgresql.username (include "vs.gen" (dict "root" . "key" "postgresPassword") | urlquery) (include "vs.postgresName" .) .Values.postgresql.database -}}
{{- else -}}
{{- .Values.externalDatabase.url -}}
{{- end -}}
{{- end }}

{{- define "vs.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "vs.postgresImage" -}}
{{- $registry := .Values.postgresql.image.registry | default .Values.global.imageRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.postgresql.image.repository .Values.postgresql.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.postgresql.image.repository .Values.postgresql.image.tag -}}
{{- end -}}
{{- end }}

{{- define "vs.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

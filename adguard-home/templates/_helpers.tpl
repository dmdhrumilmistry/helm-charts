{{- define "adguard.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "adguard.fullname" -}}
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

{{- define "adguard.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "adguard.labels" -}}
helm.sh/chart: {{ include "adguard.chart" . }}
{{ include "adguard.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: adguard-home
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "adguard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "adguard.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "adguard.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- printf "%s-credentials" (include "adguard.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "adguard.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "adguard.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Credentials

Generated once, then read back from the live cluster on upgrade. The
bcrypt hash is stored beside the password rather than recomputed,
because bcrypt salts randomly: a fresh hash every render would rewrite
the config and restart the pod on every upgrade.
=====================================================================
*/}}
{{- define "adguard.generatedSecrets" -}}
{{- if not (hasKey .Values "_agGenerated") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "adguard.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $existing -}}{{- $old = $existing.data -}}{{- end -}}
  {{- $gen := dict -}}
  {{- if .Values.auth.password -}}
    {{- $_ := set $gen "password" .Values.auth.password -}}
  {{- else if (index $old "password") -}}
    {{- $_ := set $gen "password" (index $old "password" | b64dec) -}}
  {{- else -}}
    {{- $_ := set $gen "password" (randAlphaNum 24) -}}
  {{- end -}}
  {{- $oldHash := index $old "passwordHash" -}}
  {{- $oldPass := index $old "password" -}}
  {{- if and $oldHash $oldPass (eq ($oldPass | b64dec) (index $gen "password")) -}}
    {{- $_ := set $gen "passwordHash" ($oldHash | b64dec) -}}
  {{- else -}}
    {{- $_ := set $gen "passwordHash" (htpasswd "u" (index $gen "password") | trimPrefix "u:") -}}
  {{- end -}}
  {{- $_ := set $.Values "_agGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "adguard.gen" -}}
{{- include "adguard.generatedSecrets" .root -}}
{{- index .root.Values._agGenerated .key -}}
{{- end }}

{{- define "adguard.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $tag := .Values.image.tag | default (printf "v%s" .Chart.AppVersion) -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "adguard.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

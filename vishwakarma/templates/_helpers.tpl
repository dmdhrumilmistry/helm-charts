{{- define "vk.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vk.fullname" -}}
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

{{- define "vk.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "vk.labels" -}}
helm.sh/chart: {{ include "vk.chart" . }}
{{ include "vk.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: vishwakarma
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "vk.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vk.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "vk.secretName" -}}
{{- .Values.existingSecret | default (printf "%s-secrets" (include "vk.fullname" .)) -}}
{{- end }}

{{- define "vk.sandboxNamespace" -}}
{{- .Values.sandboxes.namespace | default (printf "%s-sandboxes" (include "vk.fullname" .)) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "vk.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "vk.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{- define "vk.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "vk.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Generated credentials: created on first install, then read back from the
live Secret on every upgrade so the admin password and API token stay put.
*/}}
{{- define "vk.generated" -}}
{{- if not (hasKey .Values "_vkGenerated") -}}
  {{- $gen := dict -}}
  {{- $old := dict -}}
  {{- $live := (lookup "v1" "Secret" .Release.Namespace (include "vk.secretName" .)) -}}
  {{- if $live -}}{{- $old = $live.data | default dict -}}{{- end -}}
  {{- range $key, $spec := dict "adminPassword" (list $.Values.auth.adminPassword 24) "apiToken" (list $.Values.auth.apiToken 40) "sessionKey" (list $.Values.auth.sessionKey 64) "macosToken" (list $.Values.macos.token 40) -}}
    {{- $explicit := index $spec 0 -}}
    {{- if $explicit -}}
      {{- $_ := set $gen $key $explicit -}}
    {{- else if (index $old $key) -}}
      {{- $_ := set $gen $key (index $old $key | b64dec) -}}
    {{- else -}}
      {{- $_ := set $gen $key (randAlphaNum (int (index $spec 1))) -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $.Values "_vkGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "vk.gen" -}}
{{- include "vk.generated" .root -}}
{{- index .root.Values._vkGenerated .key -}}
{{- end }}

{{/* The Android screen sidecar, released with the server. */}}
{{- define "vk.androidScreenImage" -}}
{{- if .Values.sandboxes.androidScreenImage -}}
{{- .Values.sandboxes.androidScreenImage -}}
{{- else -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $repo := printf "%s-android-screen" .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}{{ printf "%s/%s:%s" $registry $repo $tag }}{{- else -}}{{ printf "%s:%s" $repo $tag }}{{- end -}}
{{- end -}}
{{- end }}

{{- define "vk.simulatorName" -}}
{{- printf "%s-mac-simulator" (include "vk.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Configured Mac agents plus the in-cluster simulator, as a YAML list. */}}
{{- define "vk.macAgents" -}}
{{- $agents := list -}}
{{- range .Values.macos.agents -}}
{{- $agents = append $agents (dict "name" .name "url" .url "insecureSkipVerify" (default false .insecureSkipVerify)) -}}
{{- end -}}
{{- if .Values.macos.simulator.enabled -}}
{{- $agents = append $agents (dict "name" "simulator" "url" (printf "http://%s.%s.svc:8484" (include "vk.simulatorName" .) .Release.Namespace) "insecureSkipVerify" false) -}}
{{- end -}}
{{- toYaml $agents -}}
{{- end }}

{{/* The policy file the server reads, rendered from .Values.sandboxes. */}}
{{- define "vk.policy" -}}
{{- $s := .Values.sandboxes -}}
{{- $p := dict
  "namespace" (include "vk.sandboxNamespace" .)
  "publicHost" $s.publicHost
  "defaultTTL" $s.defaultTTL
  "maxTTL" $s.maxTTL
  "maxSandboxesPerUser" (int $s.maxPerUser)
  "allowCustomImages" $s.allowCustomImages
  "allowPrivileged" $s.allowPrivileged
  "allowPrivilegedTemplates" $s.allowPrivilegedTemplates
  "macosOnLinux" $s.macosOnLinux
  "macosLinuxBaseImage" $s.macosLinuxBaseImage
  "androidScreenImage" (include "vk.androidScreenImage" .)
  "androidPlayStoreImage" $s.androidPlayStoreImage
  "androidPlayStoreUnrootedImage" $s.androidPlayStoreUnrootedImage
  "allowNodePort" $s.allowNodePort
  "storageClass" $s.storageClass
  "defaults" $s.defaults
  "limits" $s.limits
  "network" $s.network
  "vm" (dict "enabled" (toString $s.vm.enabled))
  "macos" (dict "agents" (include "vk.macAgents" . | fromYamlArray) "vnc" .Values.macos.vnc)
  "imagePullSecrets" ($s.imagePullSecrets | default list)
  "nodeSelector" ($s.nodeSelector | default dict)
  "tolerations" ($s.tolerations | default list)
-}}
{{- if $s.templates -}}
{{- $_ := set $p "templates" $s.templates -}}
{{- end -}}
{{- toYaml $p -}}
{{- end }}

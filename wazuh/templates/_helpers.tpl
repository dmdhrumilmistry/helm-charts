{{- define "wazuh.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.fullname" -}}
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

{{- define "wazuh.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.labels" -}}
helm.sh/chart: {{ include "wazuh.chart" . }}
{{ include "wazuh.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: wazuh
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "wazuh.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "wazuh.componentLabels" -}}
{{ include "wazuh.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "wazuh.componentSelectorLabels" -}}
{{ include "wazuh.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
=====================================================================
Object names
=====================================================================
*/}}
{{- define "wazuh.indexer.fullname" -}}
{{- printf "%s-indexer" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.master.fullname" -}}
{{- printf "%s-manager-master" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.worker.fullname" -}}
{{- printf "%s-manager-worker" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.cluster.fullname" -}}
{{- printf "%s-cluster" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.dashboard.fullname" -}}
{{- printf "%s-dashboard" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "wazuh.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- printf "%s-credentials" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "wazuh.certsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else -}}
{{- printf "%s-certs" (include "wazuh.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "wazuh.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "wazuh.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
In-cluster URL the manager and dashboard use to reach the indexer.
*/}}
{{- define "wazuh.indexer.url" -}}
{{- printf "https://%s:%v" (include "wazuh.indexer.fullname" .) .Values.indexer.service.port -}}
{{- end }}

{{/*
=====================================================================
Credentials

Generated once, then read back from the live cluster on upgrade. The
bcrypt hashes are stored alongside the passwords rather than recomputed,
because bcrypt salts randomly: recomputing would produce a different hash
on every render and restart the indexer on every upgrade.
=====================================================================
*/}}
{{- define "wazuh.generatedSecrets" -}}
{{- if not (hasKey .Values "_wzGenerated") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "wazuh.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $existing -}}{{- $old = $existing.data -}}{{- end -}}
  {{- $gen := dict -}}
  {{- $fresh := dict
        "indexerPassword"   (randAlphaNum 24)
        "dashboardPassword" (randAlphaNum 24)
        "apiPassword"       (randAlphaNum 24)
        "authdPass"         (randAlphaNum 32)
        "clusterKey"        (randAlphaNum 32 | lower)
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
  {{/*
  bcrypt hashes for the indexer's internal user database. Reuse the stored
  hash when the password behind it has not changed.
  */}}
  {{- range $pair := (list (list "indexerHash" "indexerPassword") (list "dashboardHash" "dashboardPassword")) -}}
    {{- $hashKey := index $pair 0 -}}
    {{- $passKey := index $pair 1 -}}
    {{- $oldHash := index $old $hashKey -}}
    {{- $oldPass := index $old $passKey -}}
    {{- if and $oldHash $oldPass (eq ($oldPass | b64dec) (index $gen $passKey)) -}}
      {{- $_ := set $gen $hashKey ($oldHash | b64dec) -}}
    {{- else -}}
      {{- $_ := set $gen $hashKey (htpasswd "u" (index $gen $passKey) | trimPrefix "u:") -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $.Values "_wzGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "wazuh.gen" -}}
{{- include "wazuh.generatedSecrets" .root -}}
{{- index .root.Values._wzGenerated .key -}}
{{- end }}

{{/*
=====================================================================
Internal PKI

The indexer's security plugin authenticates nodes and the admin client by
certificate, so a CA and three leaf certificates have to exist before
anything starts. Upstream makes you run a shell script for this; the chart
generates them and, like the credentials, reads them back on upgrade —
regenerating the CA would lock the indexer out of its own data.

Sprig can only set the Common Name on a generated certificate, so the DNs
are bare CNs and opensearch.yml is written to match.
=====================================================================
*/}}
{{- define "wazuh.generatedCerts" -}}
{{- if not (hasKey .Values "_wzCerts") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "wazuh.certsSecretName" .)) -}}
  {{- if and $existing (index $existing.data "root-ca.pem") -}}
    {{/*
    Re-emit what is already there rather than skipping the Secret. Leaving
    it out of the manifest would make Helm delete it on the next upgrade.
    */}}
    {{- $d := $existing.data -}}
    {{- $_ := set $.Values "_wzCerts" (dict
          "reused" true
          "ca" (index $d "root-ca.pem" | b64dec)
          "nodeCert" (index $d "node.pem" | b64dec) "nodeKey" (index $d "node-key.pem" | b64dec)
          "adminCert" (index $d "admin.pem" | b64dec) "adminKey" (index $d "admin-key.pem" | b64dec)
          "filebeatCert" (index $d "filebeat.pem" | b64dec) "filebeatKey" (index $d "filebeat-key.pem" | b64dec)
          "dashboardCert" (index $d "dashboard.pem" | b64dec) "dashboardKey" (index $d "dashboard-key.pem" | b64dec)) -}}
  {{- else -}}
    {{- $days := int .Values.tls.validityDays -}}
    {{- $ca := genCA (printf "%s-ca" (include "wazuh.fullname" .)) $days -}}
    {{- $ns := .Release.Namespace -}}
    {{- $idx := include "wazuh.indexer.fullname" . -}}
    {{/*
    SANs cover the Service name and the per-pod names, because the manager
    verifies the indexer's hostname in full.
    */}}
    {{- $idxNames := list $idx (printf "%s.%s" $idx $ns) (printf "%s.%s.svc" $idx $ns) (printf "%s.%s.svc.%s" $idx $ns .Values.global.clusterDomain) (printf "*.%s" $idx) (printf "*.%s.%s.svc.%s" $idx $ns .Values.global.clusterDomain) "localhost" -}}
    {{- $dash := include "wazuh.dashboard.fullname" . -}}
    {{- $dashNames := list $dash (printf "%s.%s" $dash $ns) (printf "%s.%s.svc" $dash $ns) (printf "%s.%s.svc.%s" $dash $ns .Values.global.clusterDomain) "localhost" -}}
    {{- $node := genSignedCert "indexer" (list "127.0.0.1") $idxNames $days $ca -}}
    {{- $admin := genSignedCert "admin" nil nil $days $ca -}}
    {{- $filebeat := genSignedCert "filebeat" nil (list "filebeat" "localhost") $days $ca -}}
    {{- $dashCert := genSignedCert "dashboard" (list "127.0.0.1") $dashNames $days $ca -}}
    {{- $_ := set $.Values "_wzCerts" (dict
          "reused" false
          "ca" $ca.Cert
          "nodeCert" $node.Cert "nodeKey" $node.Key
          "adminCert" $admin.Cert "adminKey" $admin.Key
          "filebeatCert" $filebeat.Cert "filebeatKey" $filebeat.Key
          "dashboardCert" $dashCert.Cert "dashboardKey" $dashCert.Key) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{- define "wazuh.cert" -}}
{{- include "wazuh.generatedCerts" .root -}}
{{- index .root.Values._wzCerts .key -}}
{{- end }}


{{/*
=====================================================================
Images
=====================================================================
*/}}
{{- define "wazuh.image" -}}
{{- $registry := .image.registry | default .root.Values.global.imageRegistry -}}
{{- $tag := .image.tag | default .root.Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "wazuh.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

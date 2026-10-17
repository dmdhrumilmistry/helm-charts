{{- define "mailserver.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mailserver.fullname" -}}
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

{{- define "mailserver.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mailserver.labels" -}}
helm.sh/chart: {{ include "mailserver.chart" . }}
{{ include "mailserver.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: mailserver
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "mailserver.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mailserver.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "mailserver.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "mailserver.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Identity

Everything domain-specific derives from .Values.domain, which has no
default, so no real domain ever has to be written into the chart.
=====================================================================
*/}}
{{- define "mailserver.domain" -}}
{{- $d := required "domain is required, e.g. --set domain=example.com" .Values.domain | lower | trimSuffix "." -}}
{{- if not (regexMatch "^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$" $d) -}}
{{- fail (printf "domain %q is not a valid domain name (no scheme, port or path)" .Values.domain) -}}
{{- end -}}
{{- $d -}}
{{- end }}

{{- define "mailserver.hostname" -}}
{{- .Values.hostname | default (printf "mail.%s" (include "mailserver.domain" .)) | lower | trimSuffix "." -}}
{{- end }}

{{- define "mailserver.postmaster" -}}
{{- .Values.postmasterAddress | default (printf "postmaster@%s" (include "mailserver.domain" .)) -}}
{{- end }}

{{/* A bare local part gets @<domain> appended. */}}
{{- define "mailserver.address" -}}
{{- if contains "@" .name -}}
{{- .name | lower -}}
{{- else -}}
{{- printf "%s@%s" (.name | lower) (include "mailserver.domain" .root) -}}
{{- end -}}
{{- end }}

{{/* Secret keys cannot contain @. */}}
{{- define "mailserver.accountKey" -}}
{{- . | replace "@" "_at_" -}}
{{- end }}

{{- define "mailserver.accountsSecretName" -}}
{{- .Values.existingAccountsSecret | default (printf "%s-accounts" (include "mailserver.fullname" .)) -}}
{{- end }}

{{- define "mailserver.dkimSecretName" -}}
{{- .Values.dkim.existingSecret | default (printf "%s-dkim" (include "mailserver.fullname" .)) -}}
{{- end }}

{{- define "mailserver.dkimSecretKey" -}}
{{- if .Values.dkim.existingSecret -}}{{ .Values.dkim.existingSecretKey }}{{- else -}}private.key{{- end -}}
{{- end }}

{{- define "mailserver.tlsSecretName" -}}
{{- .Values.tls.existingSecret | default (printf "%s-tls" (include "mailserver.fullname" .)) -}}
{{- end }}

{{/*
Fails the render early on combinations that would install but never
work, rather than leaving a pod stuck in ContainerCreating.
*/}}
{{- define "mailserver.validate" -}}
{{- if and (not .Values.tls.existingSecret) (not .Values.tls.certManager.enabled) -}}
{{- fail "TLS is required: set tls.existingSecret, or enable tls.certManager and set tls.certManager.issuerRef.name" -}}
{{- end -}}
{{- if and (not .Values.tls.existingSecret) .Values.tls.certManager.enabled (not .Values.tls.certManager.issuerRef.name) -}}
{{- fail "tls.certManager.issuerRef.name is required (a DNS-01 issuer is recommended for the mail hostname), or set tls.existingSecret" -}}
{{- end -}}
{{- if and (not .Values.existingAccountsSecret) (not .Values.accounts) -}}
{{- fail "at least one entry in accounts is required: docker-mailserver will not start without one" -}}
{{- end -}}
{{- if not (has .Values.network.inetProtocols (list "all" "ipv4" "ipv6")) -}}
{{- fail "network.inetProtocols must be all, ipv4 or ipv6" -}}
{{- end -}}
{{- if not (has .Values.network.outboundAddressPreference (list "any" "ipv4" "ipv6")) -}}
{{- fail "network.outboundAddressPreference must be any, ipv4 or ipv6" -}}
{{- end -}}
{{- if not (has .Values.mtaSts.mode (list "testing" "enforce" "none")) -}}
{{- fail "mtaSts.mode must be testing, enforce or none" -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Credentials

Generated once, then read back from the live cluster on upgrade, so
re-running helm never rotates a password or the DKIM key out from
under you. A rotated DKIM key would fail verification everywhere until
DNS caught up.
=====================================================================
*/}}
{{- define "mailserver.generatedSecrets" -}}
{{- if not (hasKey .Values "_msGenerated") -}}
  {{- $gen := dict "accounts" (list) "dkim" "" -}}
  {{- $fullName := include "mailserver.fullname" . -}}
  {{- if not .Values.existingAccountsSecret -}}
    {{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-accounts" $fullName) -}}
    {{- $old := dict -}}
    {{- if $existing -}}{{- $old = $existing.data | default dict -}}{{- end -}}
    {{- $seen := dict -}}
    {{- range .Values.accounts -}}
      {{- $name := required "every entry in accounts needs a name" .name -}}
      {{- $addr := include "mailserver.address" (dict "name" $name "root" $) -}}
      {{- if hasKey $seen $addr -}}{{- fail (printf "account %s is listed twice" $addr) -}}{{- end -}}
      {{- $_ := set $seen $addr true -}}
      {{- $key := include "mailserver.accountKey" $addr -}}
      {{- $pw := "" -}}
      {{- if .password -}}
        {{- $pw = .password -}}
      {{- else if (index $old $key) -}}
        {{- $pw = index $old $key | b64dec -}}
      {{- else -}}
        {{- $pw = randAlphaNum 24 -}}
      {{- end -}}
      {{- $_ := set $gen "accounts" (append $gen.accounts (dict "address" $addr "key" $key "password" $pw)) -}}
    {{- end -}}
  {{- end -}}
  {{- if not .Values.dkim.existingSecret -}}
    {{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-dkim" $fullName) -}}
    {{- if and $existing (index ($existing.data | default dict) "private.key") -}}
      {{- $_ := set $gen "dkim" (index $existing.data "private.key" | b64dec) -}}
    {{- else -}}
      {{- $_ := set $gen "dkim" (genPrivateKey "rsa") -}}
    {{- end -}}
  {{- end -}}
  {{- $_ := set $.Values "_msGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "mailserver.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "mailserver.mtaStsImage" -}}
{{- $registry := .Values.mtaSts.image.registry | default .Values.global.imageRegistry -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .Values.mtaSts.image.repository .Values.mtaSts.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.mtaSts.image.repository .Values.mtaSts.image.tag -}}
{{- end -}}
{{- end }}

{{- define "mailserver.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
=====================================================================
MTA-STS policy

The DNS id must change whenever the policy does, or senders keep the
cached copy for max_age. Deriving it from the policy's own hash makes
that automatic.
=====================================================================
*/}}
{{- define "mailserver.mtaStsPolicy" -}}
version: STSv1
mode: {{ .Values.mtaSts.mode }}
{{- range (.Values.mtaSts.mx | default (list (include "mailserver.hostname" .))) }}
mx: {{ . }}
{{- end }}
max_age: {{ int .Values.mtaSts.maxAge }}
{{ end }}

{{- define "mailserver.mtaStsId" -}}
{{- include "mailserver.mtaStsPolicy" . | sha256sum | trunc 20 -}}
{{- end }}

{{/*
=====================================================================
DNS records

The zone entries this deployment needs, rendered for the configured
domain. The DKIM key is filled in by the init container, which is the
only place the public half can be derived.
=====================================================================
*/}}
{{- define "mailserver.dnsRecords" -}}
{{- $domain := include "mailserver.domain" . -}}
{{- $host := include "mailserver.hostname" . -}}
==================== DNS records for {{ $domain }} ====================
<MAIL-IPv6>: the Service's EXTERNAL-IP (or the node's, with hostNetwork)

{{ $host }}.  AAAA  <MAIL-IPv6>
{{ $host }}.  A     <MAIL-IPv4>     (only if you also accept mail over IPv4)
{{ $domain }}.  MX    10 {{ $host }}.
{{ $domain }}.  TXT   "v=spf1 mx -all"
{{- if .Values.security.rspamd.enabled }}
{{ .Values.dkim.selector }}._domainkey.{{ $domain }}.  TXT  "v=DKIM1; k=rsa; p=__DKIM_PUBLIC_KEY__"
{{- end }}
_dmarc.{{ $domain }}.  TXT   "v=DMARC1; p=none; rua=mailto:dmarc-reports@{{ $domain }}"
_smtp._tls.{{ $domain }}.  TXT   "v=TLSRPTv1; rua=mailto:tls-reports@{{ $domain }}"
{{- if .Values.mtaSts.enabled }}
_mta-sts.{{ $domain }}.  TXT   "v=STSv1; id={{ include "mailserver.mtaStsId" . }}"
mta-sts.{{ $domain }}.  AAAA  <INGRESS-IPv6>   (your HTTP ingress, not the mail Service)
{{- end }}

Reverse DNS, set with whoever owns the address block (cloud console or
hosting provider, not your DNS zone):

<MAIL-IPv6>  PTR  {{ $host }}.

Then:
- SPF "mx" covers the MX host's addresses. If outbound mail leaves from
  a different address (pod egress through a node), add it: ip6:<addr>.
- Move DMARC from p=none to p=quarantine, then p=reject, once the
  reports show everything you send passes.
- Gmail and Microsoft reject IPv6 senders without a matching PTR record.
=====================================================================
{{- end }}

{{/* Ports the Service publishes, as name/port pairs. */}}
{{- define "mailserver.ports" -}}
{{- $p := list (dict "name" "smtp" "port" 25) -}}
{{- if .Values.ports.submissions }}{{ $p = append $p (dict "name" "submissions" "port" 465) }}{{ end -}}
{{- if .Values.ports.submission }}{{ $p = append $p (dict "name" "submission" "port" 587) }}{{ end -}}
{{- if .Values.ports.imaps }}{{ $p = append $p (dict "name" "imaps" "port" 993) }}{{ end -}}
{{- if .Values.ports.imap }}{{ $p = append $p (dict "name" "imap" "port" 143) }}{{ end -}}
{{- if .Values.ports.pop3s }}{{ $p = append $p (dict "name" "pop3s" "port" 995) }}{{ end -}}
{{- if .Values.ports.managesieve }}{{ $p = append $p (dict "name" "managesieve" "port" 4190) }}{{ end -}}
{{- toJson $p -}}
{{- end }}

{{/*
The mail server's own pods. Kept distinct from the base selector so the
mail Service and NetworkPolicy never pick up the MTA-STS pods.
*/}}
{{- define "mailserver.serverSelectorLabels" -}}
{{ include "mailserver.selectorLabels" . }}
app.kubernetes.io/component: mailserver
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "gitea.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gitea.fullname" -}}
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

{{- define "gitea.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gitea.labels" -}}
helm.sh/chart: {{ include "gitea.chart" . }}
{{ include "gitea.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/part-of: gitea
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "gitea.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitea.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Per-component labels.
Usage: include "gitea.componentLabels" (dict "root" $ "component" "server")
*/}}
{{- define "gitea.componentLabels" -}}
{{ include "gitea.labels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "gitea.componentSelectorLabels" -}}
{{ include "gitea.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
=====================================================================
Object names
=====================================================================
*/}}
{{- define "gitea.postgresql.fullname" -}}
{{- printf "%s-postgresql" (include "gitea.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gitea.secretName" -}}
{{- if .Values.existingSecret -}}
{{- .Values.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "gitea.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{- define "gitea.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "gitea.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
Images
=====================================================================
*/}}
{{- define "gitea.imageRef" -}}
{{- $registry := .image.registry | default "" -}}
{{- if .root.Values.global.imageRegistry -}}{{- $registry = .root.Values.global.imageRegistry -}}{{- end -}}
{{- $tag := .image.tag | default .defaultTag -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry .image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .image.repository $tag -}}
{{- end -}}
{{- end }}

{{- define "gitea.image" -}}
{{- include "gitea.imageRef" (dict "root" . "image" .Values.image "defaultTag" (printf "%s-rootless" .Chart.AppVersion)) -}}
{{- end }}

{{- define "gitea.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
  {{- range $secrets }}
  {{- if kindIs "string" . }}
  - name: {{ . }}
  {{- else }}
  - {{ toYaml . | nindent 4 | trim }}
  {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
=====================================================================
Identity
=====================================================================
*/}}
{{- define "gitea.domain" -}}
{{- required "domain is required: set it to the hostname Gitea is reached at, e.g. --set domain=git.example.com" .Values.domain -}}
{{- end }}

{{- define "gitea.rootUrl" -}}
{{- if .Values.rootUrl -}}
{{- .Values.rootUrl | trimSuffix "/" | printf "%s/" -}}
{{- else -}}
{{- printf "https://%s/" (include "gitea.domain" .) -}}
{{- end -}}
{{- end }}

{{- define "gitea.adminEmail" -}}
{{- .Values.admin.email | default (printf "%s@%s" .Values.admin.username (include "gitea.domain" .)) -}}
{{- end }}

{{/*
=====================================================================
Generated secrets

Generated once, then read back from the live cluster on upgrade so that
re-running helm never rotates SECRET_KEY (which would make every stored
2FA secret unreadable) or the database password.

Both JWT secrets are decoded by Gitea as unpadded base64url and must
decode to exactly 32 bytes, which 43 alphanumeric characters do. An
invalid one is silently regenerated and written to app.ini, which here
lives on an emptyDir, so every restart would sign users out.

The admin password gets a fixed upper/lower/digit suffix so it always
meets the default password complexity rules.
=====================================================================
*/}}
{{- define "gitea.generatedSecrets" -}}
{{- if not (hasKey .Values "_gtGenerated") -}}
  {{- $existing := (lookup "v1" "Secret" .Release.Namespace (include "gitea.secretName" .)) -}}
  {{- $old := dict -}}
  {{- if $existing -}}{{- $old = $existing.data -}}{{- end -}}
  {{- $gen := dict -}}
  {{- $fresh := dict
        "secretKey"        (randAlphaNum 64)
        "internalToken"    (randAlphaNum 64)
        "jwtSecret"        (randAlphaNum 43)
        "lfsJwtSecret"     (randAlphaNum 43)
        "metricsToken"     (randAlphaNum 40)
        "adminPassword"    (printf "%sAa1" (randAlphaNum 24))
        "postgresPassword" (randAlphaNum 32)
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
  {{- $_ := set $.Values "_gtGenerated" $gen -}}
{{- end -}}
{{- end }}

{{- define "gitea.gen" -}}
{{- include "gitea.generatedSecrets" .root -}}
{{- index .root.Values._gtGenerated .key -}}
{{- end }}

{{/*
=====================================================================
Database
=====================================================================
*/}}
{{- define "gitea.db.host" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s.%s.svc.%s:%v" (include "gitea.postgresql.fullname" .) .Release.Namespace .Values.global.clusterDomain .Values.postgresql.service.port -}}
{{- else -}}
{{- printf "%s:%v" (required "externalDatabase.host is required when postgresql.enabled is false" .Values.externalDatabase.host) .Values.externalDatabase.port -}}
{{- end -}}
{{- end }}

{{/*
=====================================================================
app.ini

Built as a dict of sections so that `config` merges over the defaults
key by key, then database settings are forced on top. Rendered with
sections sorted, the root section first.

Holds no secrets, so it lives in a ConfigMap you can read. Secrets
reach Gitea as GITEA__<section>__<KEY> environment variables, which the
image's entrypoint writes into its working copy of app.ini on every
start (see gitea.secretEnv).
=====================================================================
*/}}
{{- define "gitea.appIniDict" -}}
{{- $v := .Values -}}
{{- $domain := include "gitea.domain" . -}}
{{- $rootUrl := include "gitea.rootUrl" . -}}
{{- $ini := dict
  "" (dict
      "APP_NAME" $v.appName
      "RUN_MODE" "prod"
      "RUN_USER" "git"
      "WORK_PATH" "/var/lib/gitea")
  "server" (dict
      "PROTOCOL" "http"
      "HTTP_ADDR" "0.0.0.0"
      "HTTP_PORT" "3000"
      "DOMAIN" $domain
      "ROOT_URL" $rootUrl
      "APP_DATA_PATH" "/var/lib/gitea/data"
      "DISABLE_SSH" (not $v.ssh.enabled)
      "START_SSH_SERVER" $v.ssh.enabled
      "SSH_DOMAIN" $domain
      "SSH_PORT" ($v.ssh.service.port | toString)
      "SSH_LISTEN_PORT" "2222"
      "LFS_START_SERVER" $v.lfs.enabled
      "OFFLINE_MODE" true)
  "repository" (dict
      "ROOT" "/var/lib/gitea/git/repositories"
      "DEFAULT_PRIVATE" (ternary "private" "last" $v.security.defaultPrivateRepos)
      "DEFAULT_PUSH_CREATE_PRIVATE" $v.security.defaultPrivateRepos)
  "security" (dict
      "INSTALL_LOCK" true
      "TWO_FACTOR_AUTH" $v.security.twoFactorAuth
      "PASSWORD_COMPLEXITY" $v.security.passwordComplexity
      "MIN_PASSWORD_LENGTH" ($v.security.minPasswordLength | toString)
      "PASSWORD_CHECK_PWN" $v.security.passwordCheckPwn
      "LOGIN_REMEMBER_DAYS" ($v.security.loginRememberDays | toString)
      "REVERSE_PROXY_TRUSTED_PROXIES" $v.security.trustedProxies)
  "service" (dict
      "DISABLE_REGISTRATION" $v.security.disableRegistration
      "REQUIRE_SIGNIN_VIEW" $v.security.requireSigninView
      "DEFAULT_KEEP_EMAIL_PRIVATE" true
      "DEFAULT_ALLOW_CREATE_ORGANIZATION" $v.security.allowUserOrgCreation
      "ENABLE_NOTIFY_MAIL" $v.mailer.enabled)
  "openid" (dict
      "ENABLE_OPENID_SIGNIN" false
      "ENABLE_OPENID_SIGNUP" false)
  "session" (dict
      "PROVIDER" "db"
      "COOKIE_SECURE" (hasPrefix "https://" $rootUrl))
  "audit" (dict
      "RECORD_OUTPUT" (ternary "database" "disabled" $v.audit.enabled)
      "RETENTION_DAYS" ($v.audit.retentionDays | toString))
  "log" (dict
      "MODE" "console"
      "LEVEL" $v.log.level
      "ROOT_PATH" "/var/lib/gitea/log"
      "ENABLE_SSH_LOG" $v.log.sshLog
      "logger.access.MODE" (ternary "console" "" $v.log.accessLog))
  "metrics" (dict
      "ENABLED" $v.metrics.enabled)
  "actions" (dict
      "ENABLED" $v.actions.enabled)
  "packages" (dict
      "ENABLED" $v.packages.enabled)
  "mailer" (dict
      "ENABLED" $v.mailer.enabled)
  "cron.update_checker" (dict
      "ENABLED" false)
  "other" (dict
      "SHOW_FOOTER_VERSION" false
      "SHOW_FOOTER_TEMPLATE_LOAD_TIME" false)
-}}
{{- if $v.mailer.enabled -}}
{{- $_ := set (index $ini "mailer") "PROTOCOL" $v.mailer.protocol -}}
{{- $_ := set (index $ini "mailer") "SMTP_ADDR" (required "mailer.host is required when mailer.enabled" $v.mailer.host) -}}
{{- $_ := set (index $ini "mailer") "SMTP_PORT" ($v.mailer.port | toString) -}}
{{- $_ := set (index $ini "mailer") "FROM" ($v.mailer.from | default (printf "Gitea <gitea@%s>" $domain)) -}}
{{- $_ := set (index $ini "mailer") "USER" $v.mailer.user -}}
{{- end -}}
{{- range $section, $keys := ($v.config | default dict) -}}
{{- if hasKey $ini $section -}}
{{- $_ := set $ini $section (mergeOverwrite (index $ini $section) $keys) -}}
{{- else -}}
{{- $_ := set $ini $section $keys -}}
{{- end -}}
{{- end -}}
{{- $_ := set $ini "database" (dict
      "DB_TYPE" "postgres"
      "HOST" (include "gitea.db.host" .)
      "NAME" (ternary $v.postgresql.auth.database $v.externalDatabase.database $v.postgresql.enabled)
      "USER" (ternary $v.postgresql.auth.username $v.externalDatabase.username $v.postgresql.enabled)
      "SSL_MODE" (ternary "disable" $v.externalDatabase.sslMode $v.postgresql.enabled)) -}}
{{- toJson $ini -}}
{{- end }}

{{- define "gitea.appIni" -}}
{{- $ini := include "gitea.appIniDict" . | fromJson -}}
{{- range $key := keys (index $ini "") | sortAlpha }}
{{ $key }} = {{ index (index $ini "") $key }}
{{- end }}
{{- range $section := keys $ini | sortAlpha }}
{{- if ne $section "" }}

[{{ $section }}]
{{- $keys := index $ini $section }}
{{- range $key := keys $keys | sortAlpha }}
{{ $key }} = {{ index $keys $key }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Secrets as environment variables. The rootless image's entrypoint runs
docker-setup.sh, which applies every GITEA__<section>__<KEY> variable to
app.ini before the command starts, so these reach both the init
container's CLI calls and the web server.
*/}}
{{- define "gitea.secretEnv" -}}
{{- $secret := include "gitea.secretName" . -}}
{{- $vars := dict
      "GITEA__security__SECRET_KEY"     "secretKey"
      "GITEA__security__INTERNAL_TOKEN" "internalToken"
      "GITEA__oauth2__JWT_SECRET"       "jwtSecret"
      "GITEA__server__LFS_JWT_SECRET"   "lfsJwtSecret"
      "GITEA__database__PASSWD"         "postgresPassword"
-}}
{{- if .Values.metrics.enabled -}}
{{- $_ := set $vars "GITEA__metrics__TOKEN" "metricsToken" -}}
{{- end -}}
{{- range $name := keys $vars | sortAlpha }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ index $vars $name }}
{{- end }}
{{- if and .Values.mailer.enabled .Values.mailer.existingSecret }}
- name: GITEA__mailer__PASSWD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.mailer.existingSecret }}
      key: {{ .Values.mailer.existingSecretKey }}
{{- end }}
{{- end }}

{{/*
Paths. These match the rootless image's own defaults; set explicitly so
the CLI in the init container and the server agree on them.
*/}}
{{- define "gitea.env" -}}
- name: GITEA_APP_INI
  value: /etc/gitea/app.ini
- name: GITEA_WORK_DIR
  value: /var/lib/gitea
- name: GITEA_CUSTOM
  value: /var/lib/gitea/custom
- name: GITEA_TEMP
  value: /tmp/gitea
- name: TMPDIR
  value: /tmp/gitea
- name: HOME
  value: /var/lib/gitea/git
{{ include "gitea.secretEnv" . }}
{{- end }}

{{- define "gitea.volumeMounts" -}}
- name: config
  mountPath: /etc/gitea
- name: data
  mountPath: /var/lib/gitea
- name: tmp
  mountPath: /tmp
{{- end }}

{{/*
=====================================================================
teleport.yaml generation

Three shapes come out of here:

  teleport.config.standalone  Auth + Proxy + agents in one process
  teleport.config.auth        Auth only          (ha)
  teleport.config.proxy       Proxy only         (ha)
  teleport.config.agent       Agents only        (ha)

Schema reference (v3):
https://goteleport.com/docs/reference/deployment/config/
=====================================================================
*/}}

{{/*
teleport: stanza shared by every role.
*/}}
{{- define "teleport.config.instance" -}}
{{- $log := dict "output" .Values.log.output "severity" .Values.log.severity "format" (dict "output" .Values.log.format) -}}
{{/*
diag_addr turns on /healthz and /readyz, which is what the kubelet probes.
Without it Teleport exposes no health endpoint at all.
*/}}
{{- toYaml (dict "data_dir" .Values.dataDir "log" $log "diag_addr" (printf "0.0.0.0:%v" .Values.diagPort)) -}}
{{- end }}

{{/*
Storage. SQLite on a volume for standalone; PostgreSQL for ha.
Only the Auth Service reads this — the Proxy and agents hold no state.
*/}}
{{- define "teleport.config.storage" -}}
{{- if eq (include "teleport.isHA" .) "true" -}}
{{- $ext := .Values.externalDatabase -}}
{{- $stateDb := ternary .Values.postgresql.auth.clusterStateDatabase $ext.clusterStateDatabase .Values.postgresql.enabled -}}
{{- $auditDb := ternary .Values.postgresql.auth.auditDatabase $ext.auditDatabase .Values.postgresql.enabled -}}
{{- $storage := dict "type" "postgresql" -}}
{{- $_ := set $storage "conn_string" (include "teleport.postgresql.uri" (dict "root" . "database" $stateDb "extra" (printf "&pool_max_conns=%v" .Values.auth.postgresPoolMaxConns))) -}}
{{- if $auditDb -}}
{{- $_ := set $storage "audit_events_uri" (list (include "teleport.postgresql.uri" (dict "root" . "database" $auditDb))) -}}
{{- end -}}
{{- if .Values.auditSessionsURI -}}
{{- $_ := set $storage "audit_sessions_uri" .Values.auditSessionsURI -}}
{{- end -}}
{{- toYaml $storage -}}
{{- else -}}
{{- $storage := dict "type" "sqlite" "path" (printf "%s/backend" .Values.dataDir) -}}
{{- if .Values.auditSessionsURI -}}
{{- $_ := set $storage "audit_sessions_uri" .Values.auditSessionsURI -}}
{{- end -}}
{{- toYaml $storage -}}
{{- end -}}
{{- end }}

{{/*
auth_service.
*/}}
{{- define "teleport.config.authService" -}}
{{- $a := .Values.authentication -}}
{{- $auth := dict "enabled" true -}}
{{- $_ := set $auth "cluster_name" (include "teleport.clusterName" .) -}}
{{- $_ := set $auth "listen_addr" "0.0.0.0:3025" -}}
{{/*
multiplex puts SSH, Kubernetes, database and web traffic on the single
public port, routed by TLS ALPN. It is what makes one LoadBalancer and
one firewall rule enough.
*/}}
{{- $_ := set $auth "proxy_listener_mode" .Values.proxy.listenerMode -}}
{{- $authn := dict "type" $a.type "second_factors" $a.secondFactors -}}
{{- if has "webauthn" $a.secondFactors -}}
{{/*
WebAuthn binds credentials to an origin, so rp_id must be the domain the
browser actually shows.
*/}}
{{- $_ := set $authn "webauthn" (dict "rp_id" (include "teleport.clusterName" .)) -}}
{{- end -}}
{{- if $a.lockingMode -}}{{- $_ := set $authn "locking_mode" $a.lockingMode -}}{{- end -}}
{{- if $a.defaultSessionTTL -}}{{- $_ := set $authn "default_session_ttl" $a.defaultSessionTTL -}}{{- end -}}
{{- $_ := set $auth "authentication" $authn -}}
{{- if .Values.sessionRecording -}}
{{- $_ := set $auth "session_recording_config" (dict "mode" .Values.sessionRecording) -}}
{{- end -}}
{{/*
A static join token is only needed when other pods have to join over the
network. In standalone everything shares one process.
*/}}
{{- if eq (include "teleport.isHA" .) "true" -}}
{{- $_ := set $auth "tokens" (list (printf "proxy,node,kube,app,db:%s" (include "teleport.gen" (dict "root" . "key" "joinToken")))) -}}
{{- end -}}
{{- $auth = mergeOverwrite $auth (deepCopy (.Values.auth.extraConfig | default dict)) -}}
{{- toYaml $auth -}}
{{- end }}

{{/*
proxy_service.
*/}}
{{- define "teleport.config.proxyService" -}}
{{- $proxy := dict "enabled" true -}}
{{- $_ := set $proxy "web_listen_addr" "0.0.0.0:3080" -}}
{{- $_ := set $proxy "public_addr" (list (include "teleport.publicAddr" .)) -}}
{{- if eq .Values.proxy.listenerMode "separate" -}}
{{- $_ := set $proxy "listen_addr" "0.0.0.0:3023" -}}
{{- $_ := set $proxy "tunnel_listen_addr" "0.0.0.0:3024" -}}
{{- $_ := set $proxy "kube_listen_addr" "0.0.0.0:3026" -}}
{{- $_ := set $proxy "kube_public_addr" (list (printf "%s:3026" (include "teleport.clusterName" .))) -}}
{{- end -}}
{{- if .Values.tls.existingSecret -}}
{{/*
Teleport terminates TLS itself. It has to: ALPN routing needs the
handshake, and Kubernetes and database clients authenticate with mTLS,
which an ingress terminating TLS would break.
*/}}
{{- $_ := set $proxy "https_keypairs" (list (dict "cert_file" "/etc/teleport-tls/tls.crt" "key_file" "/etc/teleport-tls/tls.key")) -}}
{{- $_ := set $proxy "https_keypairs_reload_interval" .Values.tls.reloadInterval -}}
{{- else if .Values.tls.acme.enabled -}}
{{- $_ := set $proxy "acme" (dict "enabled" true "email" (required "tls.acme.email is required when tls.acme.enabled is true" .Values.tls.acme.email)) -}}
{{- end -}}
{{- if .Values.proxy.trustXForwardedFor -}}
{{- $_ := set $proxy "trust_x_forwarded_for" true -}}
{{- end -}}
{{- $proxy = mergeOverwrite $proxy (deepCopy (.Values.proxy.extraConfig | default dict)) -}}
{{- toYaml $proxy -}}
{{- end }}

{{/*
kubernetes_service / app_service / db_service, merged into whichever
config carries the agents.
*/}}
{{- define "teleport.config.agentServices" -}}
{{- $out := dict -}}
{{- if .Values.kubernetesAccess.enabled -}}
{{- $kube := dict "enabled" true "listen_addr" "0.0.0.0:3027" -}}
{{- $_ := set $kube "kube_cluster_name" (.Values.kubernetesAccess.clusterName | default (include "teleport.clusterName" .)) -}}
{{- if .Values.kubernetesAccess.labels -}}
{{- $_ := set $kube "labels" .Values.kubernetesAccess.labels -}}
{{- end -}}
{{- $_ := set $out "kubernetes_service" $kube -}}
{{- end -}}
{{- if .Values.apps -}}
{{- $_ := set $out "app_service" (dict "enabled" true "apps" .Values.apps) -}}
{{- end -}}
{{- if .Values.databases -}}
{{- $_ := set $out "db_service" (dict "enabled" true "databases" .Values.databases) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/*
Disabled stanzas. Teleport enables ssh_service by default, which would
turn the control-plane pod itself into an SSH target.
*/}}
{{- define "teleport.config.disabledServices" -}}
{{- toYaml (dict "ssh_service" (dict "enabled" .Values.sshService.enabled)) -}}
{{- end }}

{{/*
---------------------------------------------------------------------
Assembled configs
---------------------------------------------------------------------
*/}}
{{- define "teleport.config.standalone" -}}
{{- $instance := include "teleport.config.instance" . | fromYaml -}}
{{- $_ := set $instance "storage" (include "teleport.config.storage" . | fromYaml) -}}
{{- $cfg := dict "version" "v3" "teleport" $instance -}}
{{- $_ := set $cfg "auth_service" (include "teleport.config.authService" . | fromYaml) -}}
{{- $_ := set $cfg "proxy_service" (include "teleport.config.proxyService" . | fromYaml) -}}
{{- $cfg = merge $cfg (include "teleport.config.agentServices" . | fromYaml) -}}
{{- $cfg = merge $cfg (include "teleport.config.disabledServices" . | fromYaml) -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy (.Values.extraConfig | default dict)) -}}
{{- toYaml $cfg -}}
{{- end }}

{{- define "teleport.config.auth" -}}
{{- $instance := include "teleport.config.instance" . | fromYaml -}}
{{- $_ := set $instance "storage" (include "teleport.config.storage" . | fromYaml) -}}
{{- $cfg := dict "version" "v3" "teleport" $instance -}}
{{- $_ := set $cfg "auth_service" (include "teleport.config.authService" . | fromYaml) -}}
{{- $_ := set $cfg "proxy_service" (dict "enabled" false) -}}
{{- $cfg = merge $cfg (include "teleport.config.disabledServices" . | fromYaml) -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy (.Values.extraConfig | default dict)) -}}
{{- toYaml $cfg -}}
{{- end }}

{{- define "teleport.config.proxy" -}}
{{- $instance := include "teleport.config.instance" . | fromYaml -}}
{{- $_ := set $instance "auth_server" (include "teleport.authServerAddr" .) -}}
{{- $_ := set $instance "join_params" (dict "method" "token" "token_name" "/etc/teleport-join/token") -}}
{{- $cfg := dict "version" "v3" "teleport" $instance -}}
{{- $_ := set $cfg "auth_service" (dict "enabled" false) -}}
{{- $_ := set $cfg "proxy_service" (include "teleport.config.proxyService" . | fromYaml) -}}
{{- $cfg = merge $cfg (include "teleport.config.disabledServices" . | fromYaml) -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy (.Values.extraConfig | default dict)) -}}
{{- toYaml $cfg -}}
{{- end }}

{{- define "teleport.config.agent" -}}
{{- $instance := include "teleport.config.instance" . | fromYaml -}}
{{- $_ := set $instance "proxy_server" (include "teleport.publicAddr" .) -}}
{{- $_ := set $instance "join_params" (dict "method" "token" "token_name" "/etc/teleport-join/token") -}}
{{- $cfg := dict "version" "v3" "teleport" $instance -}}
{{- $_ := set $cfg "auth_service" (dict "enabled" false) -}}
{{- $_ := set $cfg "proxy_service" (dict "enabled" false) -}}
{{- $cfg = merge $cfg (include "teleport.config.agentServices" . | fromYaml) -}}
{{- $cfg = merge $cfg (include "teleport.config.disabledServices" . | fromYaml) -}}
{{- $cfg = mergeOverwrite $cfg (deepCopy (.Values.extraConfig | default dict)) -}}
{{- toYaml $cfg -}}
{{- end }}

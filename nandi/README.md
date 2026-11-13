# nandi

Helm chart for [nandi](https://github.com/dmdhrumilmistry/nandi), a gateway
and runtime monitor for AI agents. nandi sits between agents and the LLM APIs,
MCP servers and other agents they talk to, records every call in a signed
audit log, checks it against policy before it runs and holds risky actions for
a person to approve.

One pod runs both halves of nandi:

| Part | Service | Port | Who uses it |
|---|---|---|---|
| Proxy | `<release>-proxy` | 8787 | agents: LLM SDKs, MCP clients, A2A |
| Dashboard and admin API | `<release>-admin` | 8788 | operators, the `nandi` CLI, Prometheus |

The dashboard is the operator front end: live activity, calls waiting for
approval, tool definitions that changed, sessions, the kill switch and usage.
The admin API behind it is what the `nandi` CLI and automation use.

## Install

No required values:

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm install nandi dmdhrumilmistry/nandi --namespace nandi --create-namespace
```

Then read the admin token and open the dashboard:

```bash
kubectl -n nandi get secret nandi-admin -o jsonpath='{.data.token}' | base64 -d; echo
kubectl -n nandi port-forward svc/nandi-admin 8788:8788
# http://127.0.0.1:8788/  (paste the token under Token, top right)
```

Point agents in the cluster at the proxy:

```bash
OPENAI_BASE_URL=http://nandi-proxy.nandi:8787/openai/v1
ANTHROPIC_BASE_URL=http://nandi-proxy.nandi:8787/anthropic
```

nandi starts in **monitor mode**: every decision is computed and recorded, but
nothing is blocked. Watch what it would do on real traffic, then enforce:

```bash
helm upgrade nandi dmdhrumilmistry/nandi -n nandi --reuse-values --set config.mode=enforce
```

## Configuring nandi

`config` is nandi's own configuration file, passed through as YAML. Anything
nandi supports can go there; see the
[configuration reference](https://dmdhrumilmistry.github.io/nandi/docs/reference/configuration.html).
nandi rejects unknown keys at startup, so a typo shows up as a failing pod with
the reason in its log rather than as a silently ignored setting.

The chart owns a few keys and overrides whatever is in `config`:

| Key | Set to |
|---|---|
| `listen.proxy`, `admin.listen` | `0.0.0.0` on the container ports |
| `admin.token` | `env:NANDI_ADMIN_TOKEN`, from the admin Secret |
| `admin.ui` | `admin.ui` from values |
| `data_dir` | `/var/lib/nandi`, the persistent volume |
| `policy.rules`, `policy.cedar` | the files under `policies` |

### Routes and credentials

Keep provider keys out of agents: store them with `secretEnv` and inject them
on the route. Agents then need no provider key at all.

```yaml
config:
  routes:
    - name: openai
      prefix: /openai
      upstream: https://api.openai.com
      kind: llm
      inject_headers: { authorization: "env:OPENAI_AUTHORIZATION" }
      strip_headers: [authorization]
    - name: github
      prefix: /mcp/github
      upstream: https://api.githubcopilot.com/mcp
      kind: mcp
      inject_headers: { authorization: "env:GITHUB_AUTHORIZATION" }
secretEnv:
  OPENAI_AUTHORIZATION: "Bearer sk-..."
  GITHUB_AUTHORIZATION: "Bearer ghp_..."
```

Use `existingSecretEnv` instead of `secretEnv` to load Secrets you manage
(External Secrets, Sealed Secrets).

### Agent identity

Give each agent an API key so policies, budgets, the kill switch and the audit
trail can tell them apart. Generate a key with `nandi key generate`, give the
key to the agent (header `x-nandi-key`) and put only its hash in values:

```yaml
config:
  identity:
    allow_anonymous: false
    api_keys:
      - { agent: billing-agent, sha256: 3f0a..., groups: [finance] }
```

JWT, mTLS (`config.listen.tls`, certificates through `extraVolumes`) and
Biscuit delegation tokens are covered in the
[identity guide](https://dmdhrumilmistry.github.io/nandi/docs/operations/identity.html).

### Policies

`policies.rules` (YAML rules) and `policies.cedar` default to nandi's example
policies. Replace them, or add files with `policies.extraFiles`: `*.yaml` files
become rule files, `*.cedar` Cedar files, and anything else (a Cedar entities
JSON) is mounted for you to reference from `config`. Pods roll when a policy
changes. Test policies before deploying with `nandi policy test` and
`nandi replay`; see
[testing policy](https://dmdhrumilmistry.github.io/nandi/docs/policy/testing.html).

nandi ships ready-made [policy packs](https://dmdhrumilmistry.github.io/nandi/docs/policy/packs.html)
(coding agents, payments, production access, sensitive SaaS, outbound
messages after untrusted input). Save one and pass it as an extra file:

```sh
nandi policy pack payments > payments.yaml
helm upgrade nandi dmdhrumilmistry/nandi --reuse-values \
  --set-file 'policies.extraFiles.payments\.yaml=payments.yaml'
```

### MCP server gate

The `servers` section of `config` decides what happens to MCP servers that
are not on an approved list, run unpinned packages or change their binary.
See [capabilities and server risk](https://dmdhrumilmistry.github.io/nandi/docs/policy/capabilities.html).

```yaml
config:
  servers:
    on_unknown: deny        # quarantine servers not listed below
    approved:
      - { name: github, url: "https://api.githubcopilot.com/mcp" }
      - { name: crm, url: "http://crm-mcp.tools.svc:8080/mcp" }
```

## Exposing it

| Ingress | For | Notes |
|---|---|---|
| `ingress.admin` | the dashboard and admin API | the admin token protects everything except the dashboard page; SSE-friendly nginx annotations are set |
| `ingress.proxy` | agents outside the cluster | unbuffered, long read timeout for streaming responses and held approvals; prefer mTLS or API keys |

```bash
helm upgrade nandi dmdhrumilmistry/nandi -n nandi --reuse-values \
  --set ingress.admin.enabled=true --set ingress.admin.className=nginx \
  --set ingress.admin.host=nandi.example.com
```

## Security defaults

- Runs as uid 65532 from a `scratch` image holding only the static binary;
  read-only root filesystem, all capabilities dropped, no privilege escalation,
  `RuntimeDefault` seccomp, no service account token.
- The admin token is generated on install (40 random characters), kept on
  upgrade, and kept if the release is uninstalled
  (`helm.sh/resource-policy: keep`), so the CLI and Prometheus keep working
  across reinstalls.
- A NetworkPolicy admits the proxy port to agents (any pod by default; narrow
  it with `networkPolicy.proxy.from`) and the admin port only to the release
  namespace, the `ingress-nginx` namespace and the `monitoring` namespace.
  Egress stays open, because upstream LLM APIs and MCP servers are not known
  to the chart.
- The audit log, its Ed25519 signing key, tool pins and behaviour models live
  on the persistent volume. Disabling persistence loses them on restart; the
  install notes warn about it.

## Why one replica

nandi keeps sessions (taint, call history), held approvals and the audit log in
one process, and its database is single-writer. The chart runs a single-replica
StatefulSet with a persistent volume. To serve more agents, run one release per
team or environment; each has its own policy and audit log. An idle pod uses
about 20 MB of memory and evaluates an event in tens of microseconds, so one
pod goes a long way.

## Monitoring

```yaml
serviceMonitor:
  enabled: true
  labels: { release: kube-prometheus-stack }
```

The ServiceMonitor scrapes `/metrics` on the admin port with the admin token.
Metrics include events by kind, decisions by verdict, findings by category,
LLM tokens, approvals and evaluation latency. For traces, set
`config.telemetry.otlp_endpoint`.

## Values

| Key | Default | Description |
|---|---|---|
| `image.repository` | `docker.io/dmdhrumilmistry/nandi` | image (linux/amd64, linux/arm64) |
| `image.tag` | chart `appVersion` | image tag |
| `config` | monitor mode, OpenAI and Anthropic routes | nandi configuration, passed through |
| `policies.rules`, `policies.cedar` | example policies | rule and Cedar files |
| `policies.extraFiles` | `{}` | more files under `/etc/nandi/policies` |
| `admin.token` | generated | admin API and dashboard token |
| `admin.existingSecret`, `admin.existingSecretKey` | `""`, `token` | use your own Secret for the token |
| `admin.ui` | `true` | serve the dashboard |
| `secretEnv` | `{}` | environment from a chart-managed Secret, for `env:` references |
| `existingSecretEnv` | `[]` | Secrets loaded whole as environment |
| `extraEnv` | `[]` | extra environment variables |
| `logLevel` | `info` | log filter |
| `workerThreads` | `2` | async worker threads |
| `persistence.enabled` | `true` | keep `/var/lib/nandi` on a volume |
| `persistence.size` | `2Gi` | volume size |
| `persistence.storageClass` | `""` | storage class |
| `persistence.existingClaim` | `""` | use an existing claim |
| `service.proxy.*`, `service.admin.*` | `ClusterIP`, 8787 / 8788 | Services |
| `ingress.admin.*`, `ingress.proxy.*` | disabled | Ingresses |
| `networkPolicy.enabled` | `true` | ingress NetworkPolicy |
| `networkPolicy.proxy.from` | `[]` (any pod) | peers allowed to reach the proxy |
| `networkPolicy.admin.from` | `ingress-nginx`, `monitoring` namespaces | peers allowed to reach the admin API |
| `serviceMonitor.enabled` | `false` | Prometheus Operator ServiceMonitor |
| `resources` | 50m / 64Mi requested, 512Mi limit | container resources |
| `podSecurityContext`, `securityContext` | hardened | security contexts |
| `extraVolumes`, `extraVolumeMounts` | `[]` | for example TLS certificates |
| `nodeSelector`, `tolerations`, `affinity`, `priorityClassName` | | scheduling |

## Operating it

```bash
# With a port-forward to the admin Service and NANDI_ADMIN_TOKEN set:
nandi status   --admin http://127.0.0.1:8788
nandi tail     --admin http://127.0.0.1:8788 --min-verdict alert
nandi approvals --admin http://127.0.0.1:8788
nandi kill support-bot --admin http://127.0.0.1:8788

# Verify the audit log in place.
curl -s -H "Authorization: Bearer $NANDI_ADMIN_TOKEN" http://127.0.0.1:8788/v1/audit/verify

# Check the deployment.
helm test nandi -n nandi
```

Not included in this chart: the host sensor, which watches agent processes on
a node and has to run in the same process as the gateway it reports to, and
the optional ML classifier, which needs a glibc build and a model file.

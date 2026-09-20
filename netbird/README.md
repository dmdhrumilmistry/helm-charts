# NetBird — self-hosted Helm chart

Deploys a complete, self-hosted [NetBird](https://netbird.io) installation:
management, signal, relay, STUN, the web dashboard and PostgreSQL.

**No identity provider to register, no config files to generate.** NetBird
0.62 and later ship a built-in identity provider, so you create the first
admin from a setup wizard in the browser and add SSO (Google, Microsoft,
Okta, …) later from the dashboard if you want it.

---

## Quick start

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update

helm install netbird dmdhrumilmistry/netbird \
  --namespace netbird --create-namespace \
  --set global.domain=netbird.example.com
```

That is the whole install. One value.

Then:

1. **Point DNS at the cluster.** Create an `A` record for your domain
   pointing at the ingress controller's address.
2. **Open UDP 3478** to the same hostname — see [STUN](#stun-udp-3478).
3. **Open the domain in a browser.** You land on `/setup`; create the first
   admin account. The page closes itself once a user exists.
4. **Back up the generated secrets** — see [Secrets](#secrets).

Verify the install at any point with:

```bash
helm test netbird -n netbird
```

### Requirements

| | |
|---|---|
| Kubernetes | 1.23+ (`autoscaling/v2`, `policy/v1`) |
| Helm | 3.8+ |
| Ingress controller | ingress-nginx or Traefik, able to reach a gRPC backend over h2c |
| TLS | cert-manager, or a certificate you supply. NetBird peers reject untrusted certificates |
| Storage | a default StorageClass, unless you disable persistence |

---

## What gets deployed

| Workload | Image | Notes |
|---|---|---|
| `netbird-server` | `netbirdio/netbird-server` | Management, signal, relay, STUN and the embedded identity provider, in one container |
| `netbird-dashboard` | `netbirdio/dashboard` | Static web UI |
| `netbird-postgresql` | `postgres` | Single-replica StatefulSet, on by default |

Two Ingress objects are created on the same host, because Ingress cannot
set the backend protocol per path:

| Ingress | Paths | Backend |
|---|---|---|
| `<release>-netbird` | `/api`, `/oauth2`, `/relay`, `/ws-proxy`, `/` | HTTP |
| `<release>-netbird-grpc` | `/management.ManagementService`, `/signalexchange.SignalExchange`, `/management.ProxyService` | gRPC over h2c |

Setting `ingress.controller` to `nginx` or `traefik` applies the right
annotations for that split automatically.

---

## Configuration

### Ingress controller

```yaml
ingress:
  controller: nginx      # nginx | traefik | other
  className: nginx
  tls:
    enabled: true
    clusterIssuer: letsencrypt-prod   # cert-manager ClusterIssuer
```

`controller` only picks annotation defaults; `className` is what actually
selects the controller. For anything other than nginx or Traefik, set
`controller: other` and supply the gRPC backend annotation your controller
uses via `ingress.grpcAnnotations` (or `server.grpcService.annotations` if
it is configured on the Service).

> Without a working h2c backend, peers reach the API but never connect.
> This is the single most common way to get a half-working install.

Already terminating TLS somewhere upstream? Set `ingress.enabled: false`
and route to the Services yourself, keeping the same path split.

### Database

PostgreSQL is enabled by default and creates three databases: the main
store, the activity log and the embedded IdP.

To use a managed database instead:

```yaml
postgresql:
  enabled: false
externalDatabase:
  host: netbird-db.internal
  port: 5432
  username: netbird
  password: ""            # or set secrets via existingSecret
  database: netbird
  activityDatabase: netbird_activity
  idpDatabase: netbird_idp
  sslmode: require
```

Create all three databases first; NetBird creates its own schema inside
them but will not create the databases themselves.

Turning `postgresql.enabled` off without setting `externalDatabase.host`
falls back to SQLite on the server's volume. That works, and the chart
refuses to render if persistence is also off, but it caps you at one node.

### STUN (UDP 3478)

STUN cannot be proxied through an HTTP ingress, and NetBird advertises it
at the same hostname as everything else. So **the domain has to resolve to
an address that answers both TCP 443 and UDP 3478.**

| Setup | What to do |
|---|---|
| Single node / k3s | `server.stun.hostPort.enabled: true`, or the default LoadBalancer if your cluster binds it to the node IP |
| MetalLB | Share the ingress address with `metallb.universe.tf/allow-shared-ip` |
| AWS | A UDP NLB (see `values-aws.yaml`), then add its address as a second A record |
| GCP | An external passthrough LoadBalancer (see `values-gcp.yaml`), same idea |

Keep `externalTrafficPolicy: Local`. STUN exists to tell a client what its
public address is, and SNAT would make it report the wrong one.

### Authentication

The embedded identity provider is on by default and needs no
configuration. Optional pieces:

```yaml
server:
  config:
    auth:
      # Bootstrap the first admin instead of using the /setup wizard.
      owner:
        email: admin@example.com
        password: change-me
      # Turn local passwords off once external SSO is wired up.
      localAuthDisabled: false
```

External providers are added at runtime from **Settings → Identity
Providers** in the dashboard. No values, no restarts.

### Scaling

`server.replicaCount` stays at **1**, and the chart refuses to render if
you set autoscaling `minReplicas` higher. Open-source signal and relay
keep per-connection state in memory with no cross-replica bus, so a second
replica silently breaks peer signalling. Scaling the server horizontally
needs NetBird's Enterprise build with NATS and Redis.

The dashboard has no such constraint:

```yaml
dashboard:
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 8
    targetCPUUtilizationPercentage: 70
```

`nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints`,
`priorityClassName`, `resources` and `podDisruptionBudget` are available
on both workloads. Ready-made overlays:

```bash
helm install netbird dmdhrumilmistry/netbird \
  -n netbird --create-namespace \
  -f values-aws.yaml \
  --set global.domain=netbird.example.com
```

`values-aws.yaml` covers gp3 storage, a UDP NLB and on-demand node
placement; `values-gcp.yaml` covers premium-rwo disks and a GKE
passthrough load balancer.

### Secrets

Four secrets are generated on first install, then read back from the
cluster on every upgrade, so re-running `helm upgrade` never rotates them
by accident.

| Key | Protects |
|---|---|
| `storeEncryptionKey` | Setup keys and API tokens at rest |
| `authSecret` | Relay peer credentials |
| `sessionCookieEncryptionKey` | Embedded IdP session cookies |
| `postgresPassword` | The in-cluster database |

> `helm uninstall` deletes the Secret but not the database. Back it up
> before you need it:
>
> ```bash
> kubectl get secret -n netbird netbird-secrets -o yaml > netbird-secrets.yaml
> ```

To manage them yourself, create a Secret with those four keys and set
`existingSecret: <name>`.

---

## Values

The most commonly changed values. See [`values.yaml`](values.yaml) for the
complete, commented set.

| Key | Default | Description |
|---|---|---|
| `global.domain` | `""` | **Required.** Public FQDN |
| `global.tls` | `true` | Serve over HTTPS |
| `global.imageRegistry` | `""` | Prefix for every image |
| `server.replicaCount` | `1` | Must stay 1 |
| `server.persistence.size` | `5Gi` | GeoLite data, and SQLite if used |
| `server.stun.ports` | `[3478]` | Embedded STUN UDP ports |
| `server.stun.service.type` | `LoadBalancer` | How STUN is exposed |
| `server.stun.hostPort.enabled` | `false` | Bind STUN to node IPs instead |
| `server.config.extraConfig` | `{}` | Merged into `config.yaml` last |
| `dashboard.enabled` | `true` | Deploy the web UI |
| `dashboard.autoscaling.enabled` | `false` | HPA for the dashboard |
| `postgresql.enabled` | `true` | In-cluster database |
| `postgresql.persistence.size` | `10Gi` | Database volume |
| `externalDatabase.host` | `""` | Use a managed database instead |
| `ingress.controller` | `nginx` | Annotation preset |
| `ingress.className` | `""` | IngressClass |
| `ingress.tls.clusterIssuer` | `""` | cert-manager ClusterIssuer |
| `existingSecret` | `""` | Manage secrets yourself |

Anything the chart does not model goes through `server.config.extraConfig`,
which is merged over the generated `config.yaml` last. Schema:
[`config.yaml.example`](https://github.com/netbirdio/netbird/blob/main/combined/config.yaml.example).

---

## Troubleshooting

The commands below assume the release is named `netbird`, as in the quick
start. Objects are named after the release, and the chart name is dropped
when the release name already contains it — so `helm install netbird`
gives you `netbird-server`, while `helm install nb` gives you
`nb-netbird-server`. Adjust accordingly, or just list them:

```bash
kubectl get pods,svc,ingress,secret -n netbird -l app.kubernetes.io/instance=netbird
```

**Peers see the API but never connect.** The gRPC Ingress is not reaching
an h2c backend. Check that `ingress.controller` matches your controller,
and that the annotation landed:

```bash
kubectl get ingress -n netbird netbird-grpc -o yaml | grep -A5 annotations
kubectl get svc -n netbird netbird-server-grpc -o yaml | grep -A3 annotations
```

**Peers connect but cannot reach each other.** STUN is not reachable at the
public hostname. Test it:

```bash
kubectl get svc -n netbird netbird-server-stun
nc -zvu netbird.example.com 3478
```

**`/health` reports unhealthy.** The server's own healthcheck on port 9000
dials the relay back through the public URL and reports
`certificate_valid: false` until the public certificate is trusted. That is
why this chart uses `/api/instance` for readiness — gating readiness on
`/health` deadlocks, since the ingress will not route to an unready pod.
Once TLS is valid the endpoint clears on its own.

**The server keeps restarting after a reinstall.** The generated
`storeEncryptionKey` is gone but the database is not, so encrypted columns
no longer decrypt. Restore the Secret from your backup.

**Check the logs:**

```bash
kubectl logs -n netbird -l app.kubernetes.io/component=server --tail=100
kubectl logs -n netbird -l app.kubernetes.io/component=dashboard --tail=50
```

---

## Upgrading from chart 0.1.x

Chart 1.0.0 follows NetBird's own move to a single combined server, so the
layout changed substantially:

- The separate `management`, `signal`, `relay` and `coturn` Deployments are
  replaced by one `netbird-server` workload. Coturn is gone; the relay and
  the embedded STUN server cover what it did.
- `management.json`, `turnserver.conf` and the Let's Encrypt ConfigMaps are
  replaced by a generated `config.yaml`. TLS belongs to the ingress now.
- OIDC values (`AUTH_CLIENT_ID`, `AUTH_CLIENT_SECRET`, `AUTH_AUDIENCE`, …)
  are gone. Authentication is built in.
- PostgreSQL is deployed and used by default instead of SQLite.
- Adminer has been removed.

There is no in-place migration path. Install fresh, then re-enrol peers.

---

## License

MIT. See [LICENSE](https://github.com/dmdhrumilmistry/helm-charts/blob/main/LICENSE).

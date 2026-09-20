# Teleport — Community Edition

Self-hosted [Teleport](https://goteleport.com) CE: SSH, Kubernetes,
application and database access with short-lived certificates, single
sign-on and session recording.

Runs single-node on SQLite, or highly available on PostgreSQL.

---

## Licensing — read this first

**Teleport is AGPL-3.0 from version 15 onward.** Versions ≤14 were Apache-2.0
but are long end-of-life, so there is no supported, patched Teleport that
isn't AGPL. No Helm chart can change that.

What that does and does not mean (this is not legal advice):

| | |
|---|---|
| **Running this chart as-is** | No obligation. AGPL §13 requires offering source to network users of a **modified** version. The published image is unmodified. |
| **Teleport proxying your apps** | No obligation. Teleport is a proxy in front of your services; it isn't linked into your code and doesn't reach it. |
| **Forking or patching Teleport** and exposing it over a network | §13 applies. You must offer your users the modified source. |
| **Embedding Teleport server code** in something you ship or host | AGPL applies to the combined work. |
| **Building against `api/`** | That directory is Apache-2.0, so client tooling is unaffected. |

The practical blocker in most enterprises is a blanket OSPO policy banning
AGPL, not an actual obligation. Check your policy before you deploy —
that's a conversation to have early, not after rollout.

**This chart is MIT.** It contains no Teleport source and redistributes no
AGPL files; it only references the published community image. You can
vendor it into an MIT or Apache-2.0 repository without a licence conflict.
(Teleport's own official charts live in the AGPL repo, so vendoring *those*
into a permissively licensed repo is a conflict — which is why this chart
exists.)

---

## Quick start

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update

helm install teleport dmdhrumilmistry/teleport \
  --namespace teleport --create-namespace \
  --set clusterName=teleport.example.com
```

Then:

1. **Point DNS** at the proxy LoadBalancer:
   `kubectl get svc -n teleport teleport`
2. **Create the first user:**
   ```bash
   kubectl exec -n teleport sts/teleport -- \
     tctl users add admin --roles=editor,access --logins=root
   ```
   That prints a signup link. Open it to set a password and enrol a second factor.
3. **Connect:** `tsh login --proxy=teleport.example.com --user=admin`

> `clusterName` is baked into the cluster's certificate authorities on
> first start. Changing it later means rebuilding the cluster and
> re-enrolling every user and host. Pick the real name up front.

### Requirements

| | |
|---|---|
| Kubernetes | 1.23+ |
| Helm | 3.8+ |
| TLS | cert-manager, or Teleport's built-in ACME. Self-signed works only with `--insecure` |
| Storage | a default StorageClass (standalone mode) |
| Load balancer | a Service type that passes TLS through untouched — **not** an HTTP ingress |

---

## Why there is no ingress option

Teleport terminates TLS itself, and this chart does not put it behind an
ingress controller. That isn't a stylistic choice:

- In `multiplex` mode Teleport routes SSH, Kubernetes and database traffic
  by **TLS ALPN**, which requires seeing the handshake.
- Kubernetes and database clients authenticate with **mTLS**, which an
  ingress terminating TLS would break.

So the proxy is exposed as a `LoadBalancer` (or `NodePort`) and holds its
own certificate. If you must front it with something, that something has
to do TCP passthrough, not HTTP termination.

---

## Modes

### `standalone` (default)

One pod running Auth, Proxy and the agent services, SQLite on a
PersistentVolume, one replica. Everything works; nothing is redundant.

Good for a homelab, a team, or a proof of concept. The volume holds the
cluster's certificate authorities — **lose it and every certificate
Teleport has issued becomes invalid.**

### `ha`

Auth and Proxy as separate Deployments on a PostgreSQL backend, with agent
services in a third. Proxy replicas scale freely; Auth is bounded by
database connections and replication slots.

```yaml
mode: ha
auth:
  replicaCount: 2
proxy:
  replicaCount: 3
externalDatabase:
  host: teleport-db.internal
  username: teleport
  password: ""
  clusterStateDatabase: teleport_backend
  auditDatabase: teleport_audit
  sslmode: verify-full
auditSessionsURI: s3://my-bucket/teleport-sessions?region=eu-west-1
tls:
  existingSecret: teleport-tls
```

---

## The PostgreSQL backend has real prerequisites

Teleport's cluster-state backend uses **logical decoding** to watch for
changes. Before `mode: ha` will work, the database needs:

| Requirement | Why |
|---|---|
| PostgreSQL 13+ | Minimum supported by the backend |
| **`wal2json` plugin** | The change feed creates a logical replication slot using it. **The official `postgres` image does not ship it.** |
| `wal_level = logical` | Logical decoding. Server-start only; not settable at runtime |
| `max_replication_slots` ≥ `auth.replicaCount` | One slot per Auth replica, plus headroom |
| A role with `REPLICATION` | Needed to create the slot |
| A **direct** connection | pgbouncer is not supported |

Azure Database for PostgreSQL ships `wal2json` pre-installed. Check before
assuming any other managed service does.

Teleport creates its own databases and schema when the role owns them.

`postgresql.enabled: true` starts an in-cluster database on the
`debezium/postgres` image (which bundles `wal2json`, and is Apache-2.0) and
sets the WAL parameters for you. **That is for testing.** It is one replica
with no backups and no failover — pointing a highly available control plane
at it defeats the exercise.

### Session recordings in HA

Set `auditSessionsURI` to shared object storage. Left empty, each Auth
replica keeps recordings on its own ephemeral disk: playback hits the wrong
replica and finds nothing, and a restart loses them. The chart warns about
this on install.

---

## What you get

| Capability | Value | Notes |
|---|---|---|
| SSH access | always on | Enrol servers with `teleport node` and a join token |
| Kubernetes access | `kubernetesAccess.enabled` (default on) | Creates the impersonation ClusterRole Teleport needs |
| Application access | `apps` | Each entry becomes an `app_service` app |
| Database access | `databases` | Each entry becomes a `db_service` database |

```yaml
apps:
  - name: grafana
    uri: http://grafana.monitoring.svc.cluster.local:3000
    labels: { env: prod }

databases:
  - name: orders
    protocol: postgres
    uri: postgres.default.svc.cluster.local:5432
```

### Kubernetes RBAC

With `kubernetesAccess.enabled`, the chart creates a ClusterRole granting
`impersonate` on users, groups and service accounts, `get` on pods, and
`create` on self-subject access reviews. Teleport authenticates as itself
and then *acts as* the Kubernetes identity mapped from the user's Teleport
role — so **what a user can actually do is still governed by that user's own
Kubernetes RBAC.** The chart grants Teleport no direct access to workloads
or secrets.

---

## Community Edition limits

These are upstream product limits, not chart gaps:

- **SAML and OIDC connectors are Enterprise-only.** CE supports local users
  and GitHub SSO. Setting `authentication.type: saml` will not work.
- **Device Trust is Enterprise-only** (`mode` is always `off` in CE).
- Access Requests, Session Moderation and Hardware Key support are
  Enterprise features.

Everything else — SSH, Kubernetes, apps, databases, session recording,
audit log, RBAC — is in CE.

---

## Values

Most-changed values. See [`values.yaml`](values.yaml) for the full set.

| Key | Default | Description |
|---|---|---|
| `clusterName` | `""` | **Required.** Public FQDN, and the Teleport cluster name |
| `mode` | `standalone` | `standalone` or `ha` |
| `tls.existingSecret` | `""` | cert-manager TLS secret. Recommended |
| `tls.acme.enabled` | `false` | Built-in Let's Encrypt. Single replica only |
| `proxy.listenerMode` | `multiplex` | `multiplex` or `separate` |
| `proxy.service.type` | `LoadBalancer` | Must not be an HTTP ingress |
| `proxy.service.port` | `443` | Public port |
| `persistence.size` | `10Gi` | Standalone SQLite volume |
| `auth.replicaCount` | `2` | HA only; needs a replication slot each |
| `proxy.autoscaling.enabled` | `false` | HPA for the proxy (HA only) |
| `postgresql.enabled` | `false` | In-cluster test database |
| `externalDatabase.host` | `""` | Production HA backend |
| `auditSessionsURI` | `""` | Shared storage for recordings. Required in HA |
| `kubernetesAccess.enabled` | `true` | Kubernetes access + RBAC |
| `sessionRecording` | `node` | `node`, `node-sync`, `proxy`, `proxy-sync`, `off` |
| `extraConfig` | `{}` | Merged into `teleport.yaml` last |

Anything the chart doesn't model goes through `extraConfig`,
`auth.extraConfig` or `proxy.extraConfig`, each merged last. Schema:
[Teleport config reference](https://goteleport.com/docs/reference/deployment/config/).

---

## Troubleshooting

**`teleport: error: unexpected start`.** You passed `args` or `command` to
the container. The image entrypoint is already
`dumb-init teleport start -c /etc/teleport/teleport.yaml`; anything you add
is appended to it, not substituted.

**`tsh` refuses the certificate.** No `tls.existingSecret` and no ACME, so
Teleport self-signed. `--insecure` bypasses it for a look, but it disables
the check that stops someone impersonating your cluster. Configure a real
certificate.

**Kubernetes access works but `kubectl` is denied.** Expected — Teleport
impersonates, so the *user's* Kubernetes RBAC applies. Bind the group in
the user's Teleport role to a Kubernetes Role.

**Pod is Running but never Ready.** Readiness probes `/readyz` on the
diagnostics port. Check the logs:

```bash
kubectl logs -n teleport -l app.kubernetes.io/part-of=teleport --tail=100
```

**HA Auth won't start.** Almost always the PostgreSQL prerequisites —
usually a missing `wal2json` or `wal_level` still at `replica`. The error
mentions the replication slot.

**Useful commands** (release named `teleport`; a different release name
prefixes everything):

```bash
kubectl exec -n teleport sts/teleport -- tctl status
kubectl exec -n teleport sts/teleport -- tctl get kube_server --format=text
kubectl exec -n teleport sts/teleport -- tctl users ls
helm test teleport -n teleport
```

---

## Verified

Standalone mode on k3s 1.36: pod Ready in ~20s, `helm test` green, web UI
and `/webapi/ping` served over TLS, `tctl status` reporting all certificate
authorities active, the Kubernetes cluster self-registered, and
`tctl users add` issuing a working signup URL. `/webapi/ping` reports
`"edition":"community"` and `"tls_routing_enabled":true`.

Not verified end-to-end: HA mode against a real managed PostgreSQL, and
certificate issuance through cert-manager. Both render correctly and the
prerequisites are documented above, but neither has been run.

---

## License

This chart: MIT. See
[LICENSE](https://github.com/dmdhrumilmistry/helm-charts/blob/main/LICENSE).

Teleport itself: AGPL-3.0 — see the section at the top.

# Wazuh

Self-hosted [Wazuh](https://wazuh.com) — open source XDR and SIEM. Deploys
the indexer, manager and dashboard, and **generates the internal PKI for
you**.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update

helm install wazuh dmdhrumilmistry/wazuh \
  --namespace wazuh --create-namespace
```

No required values.

---

## Why this chart exists

Wazuh publishes Kubernetes manifests, not a Helm chart, and those
manifests assume you have already run a shell script to build an internal
certificate authority. The indexer's security plugin authenticates nodes
and the admin client **by certificate**, so nothing starts until that PKI
exists.

This chart generates it at install time — a CA plus node, admin, filebeat
and dashboard certificates — and reads it back from the cluster on
upgrade, so re-running `helm upgrade` never rotates the CA and orphans
your data. Same for the credentials, including the bcrypt hashes the
indexer needs in its internal user database.

---

## Sizing

The defaults are for a real deployment and want roughly **6 GiB** across
the stack. The indexer is the hungry part.

| | Default | Homelab overlay |
|---|---|---|
| Indexer replicas | 3 | 1 |
| Indexer heap | 2g | 768m |
| Manager | master + workers | master only |
| Rough total | ~6 GiB | ~3 GiB |

For a small node:

```bash
helm install wazuh dmdhrumilmistry/wazuh \
  -n wazuh --create-namespace \
  -f values-homelab.yaml
```

A single indexer cannot host replica shards, so indices sit at **yellow**
once data arrives. That is expected, not a fault.

---

## Credentials

Nothing is printed and nothing lands in your values file:

```bash
kubectl get secret -n wazuh wazuh-credentials \
  -o go-template='{{range $k,$v := .data}}{{$k}}={{$v|base64decode}}{{"\n"}}{{end}}'
```

| Key | Used by |
|---|---|
| `indexerPassword` | Indexer admin; also the dashboard login and the manager's filebeat output |
| `dashboardPassword` | The account the dashboard queries the indexer with |
| `apiPassword` | Wazuh manager REST API |
| `authdPass` | Pre-shared key agents present when registering |
| `clusterKey` | Binds master and workers into one Wazuh cluster |

> **Back up `wazuh-certs` and `wazuh-credentials`.** The CA is generated
> once. Losing it while keeping the indexer volume locks the cluster out
> of its own data. The certificate Secret carries
> `helm.sh/resource-policy: keep` so `helm uninstall` leaves it behind,
> but keep your own copy.

Supply your own instead with `existingSecret` and `tls.existingSecret`.

---

## Enrolling agents

Agents register against the master, then stream events:

| | Service | Port |
|---|---|---|
| Registration | `wazuh-manager-master` | 1515 |
| Events | `wazuh-manager-worker`, or the master when no workers | 1514 |
| Manager API | `wazuh-manager-master` | 55000 |

Both Services are **ClusterIP by default**, so nothing is exposed until
you ask. For agents outside the cluster:

```yaml
manager:
  master:
    service:
      type: LoadBalancer
  worker:
    service:
      type: LoadBalancer
```

---

## Clustering

`manager.worker.replicaCount` above 0 requires `manager.config`, and the
chart refuses to render otherwise.

That is not gatekeeping — the manager container runs
`cp -r /wazuh-config-mount/* /var/ossec`, so a mounted `ossec.conf`
**replaces** the image's config rather than merging with it. A cluster
needs a `<cluster>` stanza, and the only way to add one is to supply the
whole file. Anything you leave out is gone, including rule and decoder
includes.

The container fills in two placeholders at startup, so you don't have to
template them yourself:

```xml
<node_name>to_be_replaced_by_hostname</node_name>
<key>to_be_replaced_by_cluster_key</key>
```

Start from the [upstream ossec.conf
reference](https://documentation.wazuh.com/current/user-manual/reference/ossec-conf/).

Left at 0, the image's own config runs a single manager — correct for most
installs, and what the defaults do.

---

## The dashboard

Serves HTTPS with its own chart-generated certificate. If you front it
with an ingress, the controller must speak **HTTPS to the backend**:

```yaml
ingress:
  enabled: true
  controller: nginx        # or traefik
  className: nginx
  host: wazuh.example.com
  tls:
    clusterIssuer: letsencrypt-prod
```

`controller` picks the right backend-protocol annotation — on nginx that
goes on the Ingress, on Traefik on the Service. Only the dashboard can be
published this way; the agent and indexer protocols are not HTTP.

---

## Values

| Key | Default | Description |
|---|---|---|
| `indexer.replicaCount` | `3` | 1 works but stays yellow |
| `indexer.heapSize` | `2g` | Keep memory limit at ~2x this |
| `indexer.sysctlInitContainer.enabled` | `true` | Raises `vm.max_map_count`; needs a privileged container |
| `manager.config` | `""` | Full `ossec.conf`; required for clustering |
| `manager.worker.replicaCount` | `0` | Above 0 requires `manager.config` |
| `dashboard.enabled` | `true` | Web UI |
| `tls.validityDays` | `3650` | Generated certificate lifetime |
| `existingSecret` | `""` | Bring your own credentials |
| `tls.existingSecret` | `""` | Bring your own PKI |
| `global.storageClassName` | `""` | Applies to all three components |

---

## Troubleshooting

**Dashboard crashes with `EACCES ... key.pem`.** Its image runs as uid
1000 and cannot read a root-owned Secret mount. `dashboard.podSecurityContext.fsGroup`
is 1000 by default for exactly this reason — don't drop it.

**Indexer won't start, `max virtual memory areas too low`.** The sysctl
init container is disabled or was blocked. Either re-enable it or set
`vm.max_map_count=262144` on the nodes.

**Manager runs but no alerts reach the indexer.** Check filebeat's view of
the connection — it verifies the indexer's certificate in full:

```bash
kubectl exec -n wazuh wazuh-manager-master-0 -- filebeat test output
```

**Check the pipeline end to end:**

```bash
helm test wazuh -n wazuh
kubectl exec -n wazuh wazuh-indexer-0 -- \
  curl -sk -u admin:$PASS https://localhost:9200/_cat/indices?v
```

A working stack shows a `wazuh-alerts-4.x-*` index with a non-zero count.

---

## Verified

On k3s 1.36 with `values-homelab.yaml`: all three components Ready,
`helm test` green, indexer cluster **green** with the chart's own CA
trusted by `curl --cacert`, a wrong password correctly rejected with 401
(so the generated bcrypt hashes are genuinely in force), `filebeat test
output` completing a TLS handshake with chain verification enabled, and a
`wazuh-alerts-4.x` index filling with real alerts.

Not verified: master/worker clustering, and the default 3-replica indexer
— neither fits a single small node. Both render correctly.

---

## License

This chart: MIT. Wazuh: GPL-2.0, which has no network clause — running it
unmodified imposes nothing on you. The chart contains no Wazuh source and
redistributes no GPL files; it references the published images.

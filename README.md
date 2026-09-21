# helm-charts

Helm charts, served from GitHub Pages.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update
helm search repo dmdhrumilmistry
```

## Charts

| Chart | Version | App | Description |
|---|---|---|---|
| [netbird](netbird/) | 1.0.1 | 0.79.0 | Self-hosted [NetBird](https://netbird.io): a WireGuard-based overlay network with built-in local user management, PostgreSQL and no external identity provider required |
| [teleport](teleport/) | 0.1.0 | 18.10.0 | Self-hosted [Teleport](https://goteleport.com) Community Edition: SSH, Kubernetes, application and database access with short-lived certificates. Single-node or HA on PostgreSQL |

### netbird

One value to install:

```bash
helm install netbird dmdhrumilmistry/netbird \
  --namespace netbird --create-namespace \
  --set global.domain=netbird.example.com
```

Deploys management, signal, relay, STUN, the dashboard and PostgreSQL.
Create the first admin from the setup wizard in your browser; add SSO
providers later from the dashboard if you want them. Full documentation,
including AWS and GCP overlays, is in the
[chart README](netbird/README.md).

> Chart 1.0.0 is a breaking rewrite of 0.1.x with no migration path. Pin
> `--version 0.1.0` if you are not ready to reinstall.

### teleport

One value to install:

```bash
helm install teleport dmdhrumilmistry/teleport \
  --namespace teleport --create-namespace \
  --set clusterName=teleport.example.com
```

Runs `standalone` (Auth, Proxy and agents in one pod on SQLite) or `ha`
(Auth and Proxy as separate scalable Deployments on PostgreSQL). Covers
SSH, Kubernetes, application and database access. Full documentation is in
the [chart README](teleport/README.md).

> **Licensing:** the chart is MIT, but Teleport itself is AGPL-3.0 from
> v15 on. Running the published community image unmodified imposes no
> source-disclosure obligation; forking or patching it and exposing that
> over a network does. The chart carries no Teleport source, so it vendors
> cleanly into a permissively licensed repo. See the
> [chart README](teleport/README.md#licensing--read-this-first) before
> deploying somewhere with an AGPL policy.

> Teleport terminates TLS itself and cannot sit behind an HTTP ingress —
> it routes by TLS ALPN and its clients use mTLS. Expose it as a
> LoadBalancer.

## Repository layout

```
index.yaml               # repo index served at the Pages root
netbird/                 # chart source
teleport/                # chart source
*/  *.tgz                # packaged releases, alongside each chart
artifacthub-repo.yml     # Artifact Hub ownership metadata
```

## Releasing a chart

```bash
CHART=netbird            # or teleport
helm lint "$CHART"
helm package "$CHART" -d "$CHART"
helm repo index "$CHART" \
  --url "https://dmdhrumilmistry.github.io/helm-charts/$CHART" \
  --merge index.yaml
mv "$CHART/index.yaml" index.yaml
```

`--merge` keeps the entries for versions already published, so previously
released tarballs stay resolvable and their digests do not change. Commit
the new `.tgz` alongside the updated `index.yaml`.

## License

MIT. See [LICENSE](LICENSE).

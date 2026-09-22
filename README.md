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
| [wazuh](wazuh/) | 0.1.1 | 4.14.7 | Self-hosted [Wazuh](https://wazuh.com) XDR and SIEM: indexer, manager and dashboard, with the internal PKI generated for you |
| [falco](falco/) | 0.1.0 | 0.45.0 | [Falco](https://falco.org) runtime security, wrapping the official Apache-2.0 chart with opinionated defaults |
| [adguard-home](adguard-home/) | 0.1.0 | 0.107.79 | Self-hosted [AdGuard Home](https://adguard.com/adguard-home.html): network-wide DNS with ad blocking and declarative local DNS rewrites |

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

### wazuh

```bash
helm install wazuh dmdhrumilmistry/wazuh \
  --namespace wazuh --create-namespace
```

No required values. The chart generates the internal certificate
authority and every credential on first install and preserves them on
upgrade — upstream ships raw manifests plus a shell script you must run
to build that PKI before you can deploy at all. Full documentation, and a
`values-homelab.yaml` overlay for a small node, are in the
[chart README](wazuh/README.md).

> The defaults want roughly 6 GiB across the stack. Back up the generated
> `wazuh-certs` Secret: losing the CA while keeping the indexer volume
> locks the cluster out of its own data.

### falco

```bash
helm install falco dmdhrumilmistry/falco \
  --namespace falco --create-namespace
```

A thin wrapper over the official `falcosecurity/falco` chart rather than a
reimplementation — that chart is Apache-2.0, so it vendors in cleanly, and
it already solves kernel driver selection. Defaults to the `modern_ebpf`
driver (no kernel headers, no driver build, needs kernel 5.8+) with
Kubernetes metadata enrichment and JSON output on. See the
[chart README](falco/README.md).

### adguard-home

```bash
helm install adguard dmdhrumilmistry/adguard-home   --namespace adguard --create-namespace
```

Renders `AdGuardHome.yaml` from values, so the setup wizard never appears
and your local DNS names live in version control rather than in a web UI.
The point is `rewrites` — names that resolve only inside your network:

```yaml
rewrites:
  - domain: "*.home.arpa"
    answer: "10.0.0.5"
```

`.home.arpa` is reserved by RFC 8375 for home networks, so it never
collides with a real domain and never leaks to a public resolver. See the
[chart README](adguard-home/README.md).

> Point your router's DHCP at the DNS Service address and every device on
> the network resolves through it.

## Repository layout

```
index.yaml               # repo index served at the Pages root
netbird/                 # chart source
teleport/                # chart source
wazuh/                   # chart source
falco/                   # chart source (wraps an upstream dependency)
adguard-home/            # chart source
*/  *.tgz                # packaged releases, alongside each chart
artifacthub-repo.yml     # Artifact Hub ownership metadata
```

## Releasing a chart

```bash
CHART=netbird            # or teleport, wazuh, falco, adguard-home
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

Two wrinkles for `falco`, which vendors an upstream dependency:

- Package it into a temporary directory and move the result in. A `*.tgz`
  rule in `.helmignore` would also exclude `charts/`, and helm's ignore
  matcher does not honour gitignore-style leading-slash anchoring.
- `helm repo index` recurses, so it indexes the vendored
  `charts/falco-9.2.0.tgz` as if it were ours. Drop that entry afterwards;
  only the wrapper version belongs in the index.

## License

MIT. See [LICENSE](LICENSE).

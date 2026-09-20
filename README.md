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

## Repository layout

```
index.yaml               # repo index served at the Pages root
netbird/                 # chart source
netbird/*.tgz            # packaged releases
artifacthub-repo.yml     # Artifact Hub ownership metadata
```

## Releasing a chart

```bash
helm lint netbird
helm package netbird -d netbird
helm repo index netbird --url https://dmdhrumilmistry.github.io/helm-charts/netbird --merge index.yaml
mv netbird/index.yaml index.yaml
```

`--merge` keeps the entries for versions already published, so previously
released tarballs stay resolvable. Commit the new `.tgz` alongside the
updated `index.yaml`.

## License

MIT. See [LICENSE](LICENSE).

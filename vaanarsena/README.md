# vaanarsena

Self-hosted [VaanarSena](https://github.com/dmdhrumilmistry/VaanarSena):
open source device management (MDM) for iOS, iPadOS, macOS, Windows,
Android, ChromeOS and Linux, covering corporate and BYOD devices.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm install vaanarsena dmdhrumilmistry/vaanarsena \
  --namespace vaanarsena --create-namespace \
  --set publicHost=mdm.example.com
```

One required value. The chart deploys the server, a PostgreSQL StatefulSet
and an ingress-nginx Ingress. It generates the secret key, the admin
password, the database password and the device certificate authority on
first install, and preserves them on upgrade.

## Before you install

- **A public DNS name with a trusted certificate.** Apple and Windows devices
  reject self-signed server certificates. With cert-manager:

  ```yaml
  ingress:
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt
  ```

- **ingress-nginx**, if you manage Windows or Linux devices behind the ingress
  (the default). Those devices authenticate with a TLS client certificate;
  the chart configures the ingress to request one, check it against the
  device CA, and forward it to the server. Apple devices sign their requests
  instead and work behind any ingress.

## After you install

```bash
kubectl get secret -n vaanarsena vaanarsena-secrets \
  -o jsonpath='{.data.adminPassword}' | base64 -d; echo
```

Sign in at `https://<publicHost>` as `admin.email`.

> **Back up two Secrets:** `<release>-secrets` (holds `secretKey`) and
> `<release>-ca-key` (the device CA). Losing the first makes the database
> unreadable; losing the second forces every device to re-enroll. Both are
> annotated `helm.sh/resource-policy: keep`, so `helm uninstall` leaves them in
> place.

## Platforms

Windows and Linux work with no extra configuration.

**Apple** needs an MDM push certificate:

```bash
kubectl create secret generic vaanarsena-apns -n vaanarsena \
  --from-file=apns.crt --from-file=apns.key
helm upgrade vaanarsena dmdhrumilmistry/vaanarsena -n vaanarsena --reuse-values \
  --set apple.enabled=true --set apple.existingSecret=vaanarsena-apns
```

**Android and ChromeOS** need a Google service account:

```bash
kubectl create secret generic vaanarsena-google -n vaanarsena --from-file=google.json=key.json
helm upgrade vaanarsena dmdhrumilmistry/vaanarsena -n vaanarsena --reuse-values \
  --set google.existingSecret=vaanarsena-google \
  --set google.projectId=my-project \
  --set google.androidEnterprise=enterprises/LC01abcdef \
  --set google.adminSubject=admin@example.com
```

Setup for each platform is in the
[VaanarSena platform guide](https://github.com/dmdhrumilmistry/VaanarSena/blob/main/docs/platforms.md).

## Values

| Key | Default | Description |
|---|---|---|
| `publicHost` | `""` | **Required.** DNS name devices use. |
| `publicUrl` | `https://<publicHost>` | Override the public URL. |
| `orgName` | `VaanarSena` | Shown in profiles, certificates and the console. |
| `image.repository` / `image.tag` | `dmdhrumilmistry/vaanarsena` / appVersion | Server image on `ghcr.io`. |
| `replicaCount` | `1` | The server is stateless; scale freely. |
| `secretKey` | generated | At-rest encryption and session key, 32+ chars. |
| `existingSecret` | `""` | Secret with `secretKey`, `adminPassword`, `databaseUrl`. |
| `admin.email` / `admin.password` | `admin@example.com` / generated | Bootstrap admin, created only when there are no users. |
| `ca.existingSecret` | `""` | Bring your own device CA (keys `ca.crt`, `ca.key`). |
| `ca.validityDays` | `7300` | Lifetime of the generated CA. |
| `apple.enabled` / `apple.existingSecret` / `apple.topic` | `false` / `""` / `""` | APNs push certificate. |
| `google.*` | | Service account Secret, project, Android enterprise, ChromeOS admin subject, customer ID. |
| `ingress.enabled` | `true` | Create an Ingress for `publicHost`. |
| `ingress.className` | `nginx` | Ingress class. |
| `ingress.tls.secretName` | `<fullname>-tls` | TLS certificate Secret. |
| `ingress.clientCertificates` | `true` | Request and forward device client certificates (ingress-nginx). |
| `postgresql.enabled` | `true` | Bundled PostgreSQL 17. |
| `postgresql.persistence.size` | `10Gi` | Database volume. |
| `externalDatabase.url` / `existingSecret` | `""` | Use your own PostgreSQL 14+. |
| `networkPolicy.enabled` | `true` | Only the ingress controller reaches the server; only the server reaches PostgreSQL. |
| `networkPolicy.ingressNamespace` | `ingress-nginx` | Namespace of the ingress controller. |
| `podDisruptionBudget.enabled` | `false` | PDB for multi-replica installs. |
| `extraEnv` | `[]` | Extra `VS_*` variables, see the [configuration reference](https://github.com/dmdhrumilmistry/VaanarSena/blob/main/docs/configuration.md). |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | | Standard scheduling controls. |

## Why the NetworkPolicy matters

Behind ingress-nginx, a device's certificate reaches the server in the
`ssl-client-cert` header. The ingress overwrites that header on every
request, but a client that reached the pod directly could set it. Device
certificates are not secret, so the default NetworkPolicy admits only the
ingress controller's namespace. Keep it on unless you have an equivalent
control, and set `networkPolicy.ingressNamespace` if your controller lives
elsewhere.

## Testing

```bash
helm test vaanarsena -n vaanarsena
```

Checks that the server is ready (database reachable, migrations applied),
that the admin API rejects anonymous requests, and that the device CA is
published.

## Licensing

The chart is MIT. VaanarSena is Apache-2.0.

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

- **An ingress controller that forwards client certificates**, if you manage
  Windows or Linux devices behind the ingress (the default). Those devices
  authenticate with a TLS client certificate; the chart configures the
  ingress to request one and forward it to the server. Apple devices sign
  their requests instead and work behind any ingress. Supported:
  - **ingress-nginx** (`ingress.controller: nginx`, the default)
  - **Traefik**, the k3s default (`ingress.controller: traefik`): the chart
    adds a TLSOption that requests client certificates and a
    passTLSClientCert middleware

### k3s

```bash
helm install vaanarsena dmdhrumilmistry/vaanarsena \
  --namespace vaanarsena --create-namespace \
  --set publicHost=mdm.example.com \
  --set ingress.controller=traefik \
  --set ingress.tls.secretName=vaanarsena-tls
```

The NetworkPolicy then admits only `kube-system` (where k3s runs Traefik),
which k3s enforces out of the box. For a LAN-only lab without a public DNS
name, a wildcard DNS service such as `mdm.<ip>.nip.io` and a certificate
from your own CA work for the console and Linux agents (pass the CA with
`vaanarsena-agent enroll --server-ca`); Apple and Windows devices need the
CA installed as trusted first.

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

## Configuration as code

Groups (static and smart), policies (including custom Apple, Windows and
Android payloads) and blueprints can live in your Helm values. The chart
renders them into a ConfigMap, and the server applies them on start and
every `manifests.interval`:

```yaml
manifests:
  owner: helm
  prune: true               # remove what you delete from these values
  files:
    fleet.yaml: |
      apiVersion: vaanarsena.io/v1
      kind: Group
      metadata: {name: ios-needs-update}
      spec:
        kind: smart
        rules:
          match: all
          conditions:
            - {field: platform, op: in, value: [ios, ipados]}
            - {field: osVersion, op: version_lt, value: "17.0"}
      ---
      apiVersion: vaanarsena.io/v1
      kind: Blueprint
      metadata: {name: ios-update-push}
      spec:
        groups: [ios-needs-update]
        onEnroll:
          - {type: os_update}
```

Or keep the files in your own ConfigMap (`manifests.existingConfigMap`), for
example one Argo CD or Flux syncs from Git. Updates reach the running pod
without a restart. Validation errors are logged and leave the last good
state in place. Format reference:
[manifests.md](https://github.com/dmdhrumilmistry/VaanarSena/blob/main/docs/manifests.md).

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
| `ingress.controller` | `nginx` | `nginx`, `traefik` (k3s) or `other`; selects how client certificates are requested and forwarded. |
| `ingress.className` | controller name | Ingress class. |
| `ingress.tls.secretName` | `<fullname>-tls` | TLS certificate Secret. |
| `ingress.clientCertificates` | `true` | Request and forward device client certificates (ingress-nginx). |
| `postgresql.enabled` | `true` | Bundled PostgreSQL 17. |
| `postgresql.persistence.size` | `10Gi` | Database volume. |
| `externalDatabase.url` / `existingSecret` | `""` | Use your own PostgreSQL 14+. |
| `networkPolicy.enabled` | `true` | Only the ingress controller reaches the server; only the server reaches PostgreSQL. |
| `networkPolicy.ingressNamespace` | from controller | Namespace of the ingress controller: `ingress-nginx` for nginx, `kube-system` for traefik. |
| `podDisruptionBudget.enabled` | `false` | PDB for multi-replica installs. |
| `manifests.files` | `{}` | File name to manifest YAML; rendered into a ConfigMap and reconciled. |
| `manifests.existingConfigMap` | `""` | Use your own ConfigMap of manifests instead. |
| `manifests.interval` / `owner` / `prune` | `5m` / `helm` / `false` | Reconcile interval, owner label, and whether to delete resources removed from the manifests. |
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

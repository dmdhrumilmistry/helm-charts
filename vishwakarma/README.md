# vishwakarma

Self-hosted [Vishwakarma](https://github.com/dmdhrumilmistry/vishwakarma):
throwaway containers, Android, Linux VMs and macOS for testing apps and
endpoint tools, with a web console, browser terminal and automatic expiry.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm install vishwakarma dmdhrumilmistry/vishwakarma \
  --namespace vishwakarma --create-namespace
kubectl port-forward -n vishwakarma svc/vishwakarma 8080:8080
```

No required values. The chart deploys the server, a dedicated sandbox
namespace (`<release>-sandboxes`) with a default-deny ingress policy, and a
namespaced Role for the server there. The admin password, API token and
session key are generated on first install and preserved on upgrade.

```bash
kubectl get secret -n vishwakarma vishwakarma-secrets \
  -o jsonpath='{.data.adminPassword}' | base64 -d; echo
```

## Virtual machines

VM sandboxes need [KubeVirt](https://kubevirt.io) on the cluster; the server
detects it and shows VM templates once it is installed. Nodes without
`/dev/kvm` can run guests with software emulation. See
[docs/vms.md](https://github.com/dmdhrumilmistry/vishwakarma/blob/main/docs/vms.md).

## Android

```yaml
sandboxes:
  allowPrivilegedTemplates: true
```

The Android 12 template (redroid) needs a privileged container and the
`binder_linux` kernel module on the nodes. Its screen shows in the console's
Screen tab through a scrcpy sidecar, with copy and paste;
`adb connect <node>:<nodePort>` and scrcpy work too.

Google Play variants come by default: "Android 12 with Play Store" and
"Android 12 with Play Store (unrooted)" (no su, a production build, for apps
that refuse rooted devices). Point `sandboxes.androidPlayStoreImage` and
`androidPlayStoreUnrootedImage` at your own builds, or set them to `""` to
remove the templates. See
[docs/android.md](https://github.com/dmdhrumilmistry/vishwakarma/blob/main/docs/android.md).

## macOS and the iOS Simulator

macOS VMs run on Apple Silicon Macs through Tart, never in the cluster.
Run `vishwakarma agent` on each Mac with the shared token (NOTES shows how
to read it) and register it:

```yaml
macos:
  agents:
    - name: mac-mini-1
      url: http://192.168.1.20:8484
```

For k3s inside Lima, Colima or Rancher Desktop on the same Mac, use
`http://host.lima.internal:8484`.

`sandboxes.macosOnLinux=true` adds a Docker-OSX template (macOS installer
under QEMU). It uses `/dev/kvm` when a node has it and software emulation
(very slow) otherwise, and reserves 4.5 GiB of memory. Apple's license only
permits macOS on Apple hardware, so this is off by default. To try the flow on a Linux cluster without
a Mac, set `macos.simulator.enabled=true`: an in-cluster agent simulates VMs
(no real guest) and publishes forwarded ports as NodePorts 30500-30509. See
[docs/macos.md](https://github.com/dmdhrumilmistry/vishwakarma/blob/main/docs/macos.md).

## k3s with Traefik

```bash
helm install vishwakarma dmdhrumilmistry/vishwakarma \
  --namespace vishwakarma --create-namespace \
  --set ingress.enabled=true \
  --set ingress.className=traefik \
  --set ingress.host=sandboxes.example.com \
  --set ingress.tls.secretName=sandboxes-tls \
  --set sandboxes.publicHost=192.168.1.10
```

`sandboxes.publicHost` is the address shown for NodePort endpoints (a node IP
or a name resolving to your nodes). For a LAN lab without TLS, set
`ingress.tls.enabled=false` and `auth.secureCookies=false`, and use a
wildcard DNS name such as `sandboxes.<ip>.nip.io`.

## Multi-user

Put an identity proxy in front of the ingress and switch to header mode:

```yaml
auth:
  mode: header
  userHeader: X-Forwarded-User
  adminUsers: [you@example.com]
```

Each user then sees only their own sandboxes and gets their own quota
(`sandboxes.maxPerUser`). The server trusts the header, so it must be
reachable only through the proxy; the chart NetworkPolicy admits only
`networkPolicy.allowNamespaces` (default `kube-system`, where k3s runs
Traefik).

## Values

| Value | Default | Meaning |
|---|---|---|
| `auth.mode` | `password` | `password` (one admin) or `header` (identity proxy) |
| `existingSecret` | | Secret with `adminPassword`, `apiToken`, `sessionKey` |
| `sandboxes.namespace` | `<fullname>-sandboxes` | Where sandboxes live |
| `sandboxes.createNamespace` | `true` | Uninstalling then deletes every sandbox |
| `sandboxes.podSecurityLevel` | | PSA level for the namespace; VMs and privileged need `privileged` |
| `sandboxes.defaultTTL` / `maxTTL` | `4h` / `72h` | Lifetime; sandboxes delete themselves after it |
| `sandboxes.maxPerUser` | `5` | Per-user quota (admins exempt) |
| `sandboxes.allowCustomImages` | `true` | Any image, not only templates |
| `sandboxes.allowPrivileged` | `false` | Privileged containers; they can take over the node |
| `sandboxes.allowPrivilegedTemplates` | `false` | Privileged only from templates marked so (Android) |
| `sandboxes.macosOnLinux` | `false` | Docker-OSX template; needs `/dev/kvm`, not licensed by Apple |
| `sandboxes.androidScreenImage` | release image | Android screen sidecar |
| `sandboxes.androidPlayStoreImage` | published image | Google Play redroid; empty removes the template |
| `sandboxes.androidPlayStoreUnrootedImage` | published image | The same without root; empty removes the template |
| `sandboxes.allowNodePort` | `true` | Expose sandbox ports on every node |
| `sandboxes.defaults` / `limits` | `1`, `1Gi`, `10Gi` / `4`, `8Gi`, `50Gi` | CPU, memory, disk |
| `sandboxes.network.isolate` | `true` | Per-sandbox NetworkPolicy |
| `sandboxes.network.blockCIDRs` | k3s pod and service CIDRs | Egress denied to these; set your cluster's |
| `sandboxes.network.blockAPIServer` | `true` | Also deny the API server endpoint IPs |
| `sandboxes.vm.enabled` | `auto` | Use KubeVirt when present |
| `sandboxes.templates` | built-in | Template catalogue, see the configuration docs |
| `sandboxes.resourceQuota.enabled` | `false` | Hard ceiling for all sandboxes together |
| `macos.agents` | `[]` | Mac hosts running `vishwakarma agent` (`name`, `url`) |
| `macos.token` | generated | Shared agent token (Secret key `macosToken`) |
| `macos.simulator.enabled` | `false` | In-cluster simulated Mac for testing on Linux |
| `ingress.enabled` | `false` | Ingress for the console (`className`, `host`, `tls`) |
| `service.type` | `ClusterIP` | `NodePort` for a quick lab |
| `networkPolicy.enabled` | `true` | Restrict who reaches the server |

All values are documented in [values.yaml](values.yaml). Templates and the
policy file format are described in
[docs/configuration.md](https://github.com/dmdhrumilmistry/vishwakarma/blob/main/docs/configuration.md).

## Security

Sandboxes run untrusted code by design. Sandbox pods get no service account
token, and each one is isolated by a NetworkPolicy from other sandboxes, the
cluster networks and the API server. Keep `allowPrivileged` off unless the
cluster is dedicated to testing, and keep the console off the public
internet. On multi-node clusters add the node CIDR to
`sandboxes.network.blockCIDRs`.

## Tests

```bash
helm test vishwakarma -n vishwakarma
```

Checks readiness (API server reachable, sandbox namespace readable), that
the API rejects anonymous requests, and that the console is served.

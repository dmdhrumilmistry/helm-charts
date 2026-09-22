# AdGuard Home

Network-wide DNS with ad blocking and **local DNS rewrites** — names that
resolve only inside your network, with no query ever leaving it.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update

helm install adguard dmdhrumilmistry/adguard-home \
  --namespace adguard --create-namespace
```

---

## Why this chart exists

AdGuard Home publishes no Helm chart, and normally you configure it by
clicking through a setup wizard and then a web UI. That works, but the
result lives only on a volume: nothing is reproducible, and the DNS
rewrites that make it useful in a homelab are invisible to version
control.

This chart **renders `AdGuardHome.yaml` from values**, so the wizard never
appears and your rewrites are declarative. The schema was verified against
a running v0.107.79 instance rather than written from documentation.

---

## Local names

The point of running your own resolver:

```yaml
rewrites:
  - domain: "*.home.arpa"
    answer: "10.0.0.5"        # your ingress controller
  - domain: "nas.home.arpa"
    answer: "10.0.0.20"
```

A wildcard sends every subdomain to one address, so any service you add
behind an ingress later resolves with no further DNS work.

**Use `.home.arpa`.** RFC 8375 reserves it for home networks, so it can
never collide with a real domain and never leaks to a public resolver.
`.local` is reserved for mDNS and will confuse things; `.lan` and `.home`
are squatted but unofficial.

> `enabled: true` is added to each rewrite for you. AdGuard's config
> struct zero-values that field, so a rewrite written without it lands in
> the config and silently never matches — a genuinely confusing failure.

---

## Pointing your network at it

```bash
kubectl get svc -n adguard adguard-adguard-home-dns
```

Set that `EXTERNAL-IP` as the DNS server in your **router's DHCP
settings**, and every device resolves through AdGuard. Until you do, only
clients pointed at it directly will see your rewrites.

`externalTrafficPolicy: Local` is the default and worth keeping — it
preserves the querying client's address. Without it every query appears
to come from a cluster node, so per-client rules never match and the
statistics are meaningless.

DNS is not HTTP, so it cannot be published through an ingress. The web UI
can be (`ingress.enabled`), but the DNS Service is the part that matters.

---

## Configuration drift

AdGuard rewrites its own config file whenever you change a setting in the
web UI. So the chart **seeds the config on first start and then leaves it
alone** — an init container copies it only if the file is absent.

That means changes to your values do *not* overwrite later UI edits. It's
a deliberate trade: the alternative silently discards anything you change
in the UI on every restart.

To re-seed from values:

```bash
kubectl exec -n adguard adguard-adguard-home-0 -- rm /opt/adguardhome/conf/AdGuardHome.yaml
kubectl rollout restart -n adguard sts/adguard-adguard-home
```

---

## Values

| Key | Default | Description |
|---|---|---|
| `rewrites` | `[]` | Local DNS names. The reason to run this |
| `dns.service.type` | `LoadBalancer` | Must be reachable from your LAN |
| `dns.service.loadBalancerIP` | `""` | Pin the address your router points at |
| `dns.upstreams` | Quad9 DoH | Encrypted, so your ISP cannot read your queries |
| `dns.port` | `53` | Below 1024, hence `NET_BIND_SERVICE` |
| `auth.username` | `admin` | Web UI login |
| `auth.password` | `""` | Generated and preserved if empty |
| `filters` | AdGuard default list | Blocklists |
| `persistence.size` | `5Gi` | Query logs, statistics, downloaded lists |
| `extraConfig` | `{}` | Merged into the generated config last |

---

## Troubleshooting

**A rewrite returns NXDOMAIN.** Check it is actually enabled on the
volume — this is the failure the chart exists to prevent:

```bash
kubectl exec -n adguard adguard-adguard-home-0 -- \
  grep -A3 '  rewrites:' /opt/adguardhome/conf/AdGuardHome.yaml
```

**Config changes have no effect.** Expected — see *Configuration drift*.

**The pod crashes with `stat /opt/adguardhome/AdGuardHome: no such file`.**
Something mounted a volume over `/opt/adguardhome`, hiding the binary.
The chart mounts `conf/` and `work/` as subdirectories precisely to avoid
this; check any `extraVolumeMounts` you added.

**DNS Service stuck pending.** No LoadBalancer implementation. On bare
metal use MetalLB, or set `dns.service.type: NodePort` — though then port
53 is not where clients expect it.

---

## Verified

On k3s 1.36: pod Ready in ~20s, `helm test` green, the web UI serving a
login rather than the setup wizard, a wildcard `*.home.arpa` rewrite
resolving a name invented at test time, and public names still forwarding
to the configured upstream.

---

## License

This chart: MIT. AdGuard Home: GPL-3.0, which has no network clause — so
running it unmodified imposes nothing on you. The chart contains no
AdGuard source and references the published image.

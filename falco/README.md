# Falco

Runtime security for Kubernetes — detects suspicious syscall activity in
containers and on the host, in real time.

```bash
helm repo add dmdhrumilmistry https://dmdhrumilmistry.github.io/helm-charts
helm repo update

helm install falco dmdhrumilmistry/falco \
  --namespace falco --create-namespace
```

---

## This wraps the official chart, deliberately

Unlike the other charts here, this one does **not** reimplement anything.
It declares [`falcosecurity/falco`](https://github.com/falcosecurity/charts)
`9.2.0` as a dependency and layers opinionated defaults on top.

Two reasons:

- **No licence conflict.** Falco and its chart are Apache-2.0, which
  vendors into an MIT repository cleanly. (The Teleport chart here *is*
  written from scratch, because Teleport's charts are AGPL-3.0 and could
  not be vendored.)
- **Driver handling is the hard part.** Falco needs a kernel driver, and
  upstream already solves selection and fallback across kernel versions.
  A from-scratch chart would reimplement that and quietly be worse.

The full upstream value set is available under the `falco:` key:

```bash
helm show values falcosecurity/falco --version 9.2.0
```

---

## What the defaults change

| Setting | Default here | Why |
|---|---|---|
| `driver.kind` | `modern_ebpf` | A CO-RE probe: no kernel headers, no compilation, no privileged driver-loader. Needs kernel 5.8+ |
| `collectors.kubernetes.enabled` | `true` | Without it, alerts name a container id and little else — no pod, namespace or image |
| `falco.json_output` | `true` | So a log pipeline can parse alerts instead of scraping free text |
| `falco.buffered_outputs` | `false` | Buffering loses alerts under syscall load |
| `metrics.enabled` | `true` | Prometheus-scrapable internal metrics |
| `tolerations` | control-plane | Falco reads syscalls on every node, including control-plane ones |
| `falcosidekick.enabled` | `false` | A second workload plus Redis, useless until an output is configured |

### Older kernels

`modern_ebpf` needs 5.8+. Below that:

```yaml
falco:
  driver:
    kind: ebpf     # or `module` where eBPF is unavailable
```

Both pull in the driver-loader init container, which builds or downloads a
driver and needs more privilege.

---

## Custom rules

Upstream's `customRules` is a filename → rule-body map; the chart turns
each entry into a ConfigMap and mounts it **after** its own rule files, so
a rule here overrides an upstream rule of the same name.

```yaml
falco:
  customRules:
    rules-local.yaml: |-
      - rule: Shell spawned in container
        desc: An interactive shell started inside a container.
        condition: >
          spawned_process and container and shell_procs and proc.tty != 0
        output: >
          Shell opened in a container (user=%user.name
          container=%container.name image=%container.image.repository
          pod=%k8s.pod.name ns=%k8s.ns.name command=%proc.cmdline)
        priority: NOTICE
        tags: [container, shell]
```

Left empty by default on purpose — Falco's bundled rules are curated and
versioned, and quietly layering on top makes it unclear which rule fired
and whether an upgrade changed it.

---

## Sending alerts somewhere

Falcosidekick fans alerts out to Slack, webhooks, S3, Loki and others:

```yaml
falco:
  falcosidekick:
    enabled: true
    webui:
      enabled: true          # adds Redis
    config:
      slack:
        webhookurl: https://hooks.slack.com/services/...
        minimumpriority: warning
```

---

## Verifying it works

Falco is quiet until something trips a rule, so the useful test is to
trip one:

```bash
kubectl run trip --rm -it --restart=Never --image=busybox -- \
  sh -c 'cat /etc/shadow'

kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --tail=50 \
  | grep '"rule"'
```

You should see `Read sensitive file untrusted`.

Confirm the driver actually loaded:

```bash
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco | grep -i "probe\|engine"
```

`Opening 'syscall' source with modern BPF probe` means `modern_ebpf` is in
use and no driver was built.

---

## Verified

On k3s 1.36, kernel 7.0.0: the modern BPF probe loaded with no driver
build (`scap.engine_name: modern_bpf`), the k8s-metacollector came up,
JSON output and metrics were active, and a real detection fired —
`Read sensitive file untrusted`, from a test pod reading `/etc/shadow`.

---

## License

This wrapper: MIT. Falco and the upstream chart: Apache-2.0.

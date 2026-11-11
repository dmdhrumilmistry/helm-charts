# gitea

A self-hosted Git forge for Kubernetes: [Gitea](https://about.gitea.com)
with audit logging on, 2FA enforced, registration off, sign-in required
to see anything and repositories private by default. It runs as one
rootless pod with a read-only root filesystem, next to a bundled
PostgreSQL that only Gitea can reach.

The chart has one required value, `domain`. Every secret and the first
admin account are generated on install and preserved on upgrade.

- [Why Gitea](#why-gitea) - how it compares with GitLab, Forgejo and OneDev
- [Install](#install)
- [Security defaults](#security-defaults)
- [Audit logging](#audit-logging)
- [Ports](#ports)
- [Values](#values)
- [Operating it](#operating-it)

## Why Gitea

The brief: a self-hosted GitHub alternative with the best security and
auditing you can get, for the least maintenance. As of October 2026:

| | **Gitea 28** | Forgejo | GitLab CE (Free) | OneDev |
|---|---|---|---|---|
| Licence | MIT | GPL-3.0+ | MIT (CE) | MIT (CE) |
| **Audit log in the free build** | **Yes**, since 28.0.0: instance, org, repo and user views, filter by actor/action/origin, JSONL export, retention setting | No, [requested](https://codeberg.org/forgejo/forgejo/issues/6982), not shipped | **Sign-in events only**. Group, project and instance audit events are Premium/Ultimate | No, audit log is Enterprise Edition only |
| Enforced 2FA for everyone | Yes (`TWO_FACTOR_AUTH = enforced`) | Yes | Yes | Yes |
| Branch protection, signed commits, CODEOWNERS | Yes; 28 adds "require CODEOWNERS approval" | Yes | Yes (some rules paid) | Yes |
| Built-in CI | Actions (GitHub-compatible) | Actions | GitLab CI | Yes |
| Footprint (approx.) | ~150-300 MiB RAM, one Go binary | Same as Gitea | 4-8 GiB RAM; Rails, Sidekiq, Gitaly, Redis, Postgres | ~1 GiB (JVM) |
| Upgrades | Replace the image; schema migrates on start | Same | Must step through required upgrade stops; many components | Replace the image |
| Commercial backing | CommitGo (Gitea Enterprise adds more audit events, SAML) | Codeberg e.V., community | GitLab Inc. | Vendor |

**Pick Gitea.** It is the only one that pairs a real, free audit log with
a single-binary, low-maintenance footprint. GitLab is the most
feature-complete, but its useful audit events sit behind a paid tier and
it is the heaviest thing on this list to keep running. Forgejo is the
choice if community governance matters more than auditing to you; this
chart would port to it with an image swap, but you would lose the audit
log. OneDev is pleasant but keeps auditing for its paid edition.

Footprint figures are typical small-team numbers, not benchmarks.

Sources: [Gitea 28.0.0 release notes](https://blog.gitea.com/release-of-28.0.0/),
[Gitea config cheat sheet](https://docs.gitea.com/administration/config-cheat-sheet),
[GitLab audit events tiers](https://docs.gitlab.com/user/compliance/audit_events/),
[Forgejo audit log request](https://codeberg.org/forgejo/forgejo/issues/6982),
[OneDev EE audit log](https://onedev.io/blogs/24).

## Install

Prerequisites: an ingress controller, and either
[cert-manager](https://cert-manager.io) or an existing TLS Secret for
your domain.

```bash
helm install git dmdhrumilmistry/gitea \
  --namespace gitea --create-namespace \
  --set domain=git.example.com \
  --set ingress.className=nginx \
  --set-string 'ingress.annotations.cert-manager\.io/cluster-issuer=letsencrypt'
```

Then follow the printed notes: read the admin password from the Secret,
sign in, enrol 2FA, and run `helm test`.

Keep site-specific values out of version control: pass them with
`--set`, or put them in a file matching `*-test-values.yaml`, which this
repository already ignores.

## Security defaults

Everything below is a value you can loosen; the defaults are the locked
down end of what Gitea offers.

| Setting | Default | Value |
|---|---|---|
| 2FA (TOTP or passkey) for every account | Enforced | `security.twoFactorAuth` |
| Self-registration | Off; admins create accounts | `security.disableRegistration` |
| Anonymous browsing and API | Off; everything requires sign-in | `security.requireSigninView` |
| OpenID sign-in and sign-up | Off | `config.openid` |
| New repositories | Private | `security.defaultPrivateRepos` |
| Users creating organisations | Admins only | `security.allowUserOrgCreation` |
| Passwords | 12+ characters, upper, lower and digit | `security.minPasswordLength`, `security.passwordComplexity` |
| "Remember me" | 7 days | `security.loginRememberDays` |
| Sessions | Stored in the database; cookies `Secure` on https | |
| Gravatar, update checker, footer version | Off (offline mode) | `config` |
| Gitea Actions (CI) | Off | `actions.enabled` |
| Install page | Locked | |

The pod runs as UID 1000 from the rootless image with a read-only root
filesystem, all capabilities dropped, no privilege escalation, the
`RuntimeDefault` seccomp profile and no service account token. app.ini
lives in a ConfigMap and holds no secrets; they reach Gitea as
`GITEA__section__KEY` environment variables from the chart's Secret,
which the image's entrypoint applies on start.

NetworkPolicies admit only the web and SSH ports to Gitea, and only
Gitea to PostgreSQL. PostgreSQL gets no egress at all. To restrict the
web port to your ingress controller:

```yaml
networkPolicy:
  http:
    from:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: ingress-nginx
      # Keep helm test and Prometheus working:
      - podSelector: {}
```

## Audit logging

Gitea 28.0.0 added audit logging to the open source build. The chart
turns it on (`audit.enabled`) and keeps a year of events
(`audit.retentionDays`; `0` keeps them forever).

- **What is recorded:** security-relevant events such as sign-ins, 2FA
  and credential changes, access tokens, SSH and GPG keys,
  permission, team and membership changes, repository settings and
  deletions, with actor, action and origin.
- **Where to read it:** Site Administration, plus per organisation,
  repository and user settings pages. Filter by actor, action and
  origin; admins can export JSONL.
- **Where it lives:** in the database, so a database backup is an audit
  log backup. Gitea prunes events older than the retention with its
  own cron task.

For a SIEM, the chart also writes to stdout:

- the **access log** (`log.accessLog`), one line per HTTP request with
  user, client address and status;
- the **SSH log** (`log.sshLog`), connections and authentication failures.

Any agent that ships container logs collects them; the
[wazuh](../wazuh/) chart in this repository works. Client addresses
come from `X-Forwarded-For`, which Gitea only believes from
`security.trustedProxies`. Narrow that to your ingress controller's pod
range and restrict `networkPolicy.http.from` to the controller, or a
pod in the cluster could forge the address an event is attributed to.

## Ports

| Port | Service | Who connects | Why |
|---|---|---|---|
| 3000 | `<release>-gitea` | Your ingress controller | Web UI, API, Git over HTTPS, LFS, package registries, `/metrics` |
| 2222 (Service port 22) | `<release>-gitea-ssh` | Developers | Git over SSH. `ClusterIP` by default; set `ssh.service.type=LoadBalancer` to publish it. HTTP ingresses cannot carry SSH |
| 5432 | `<release>-gitea-postgresql` | Gitea only | Database. Fenced by NetworkPolicy |

Outbound: mirrors, migrations, webhooks and SMTP go wherever your users
point them, so egress from Gitea is not restricted.

## Values

Most-changed values. See [`values.yaml`](values.yaml) for the full set.

| Key | Default | Description |
|---|---|---|
| `domain` | `""` | **Required.** Hostname Gitea is reached at |
| `rootUrl` | `https://<domain>/` | Public URL |
| `admin.username` | `gitea-admin` | First admin, created if missing |
| `admin.password` | generated | Read back from the Secret |
| `existingSecret` | `""` | Bring your own secrets |
| `security.*` | locked down | See [Security defaults](#security-defaults) |
| `audit.enabled` | `true` | Record security events in the database |
| `audit.retentionDays` | `365` | `0` keeps forever |
| `log.accessLog` | `true` | HTTP access log on stdout |
| `actions.enabled` | `false` | Gitea Actions CI (needs act_runner) |
| `mailer.enabled` | `false` | SMTP for notifications and resets |
| `config` | `{}` | Any app.ini section/key, merged last |
| `persistence.size` | `20Gi` | Repositories, LFS, packages, indexes |
| `ingress.enabled` | `true` | HTTP ingress for `domain` |
| `ssh.service.type` | `ClusterIP` | `LoadBalancer` to publish SSH |
| `networkPolicy.http.from` | `[]` (any) | Restrict who reaches the web port |
| `metrics.serviceMonitor.enabled` | `false` | Prometheus Operator scrape, with the token |
| `postgresql.enabled` | `true` | Bundled single-pod PostgreSQL 17 |
| `externalDatabase.host` | `""` | Managed PostgreSQL instead |

## Operating it

**Upgrades.** Bump the chart; the init container runs `gitea migrate`
before the server starts. Read the Gitea release notes for breaking
changes before crossing a major version. Gitea runs as a single
replica, so an upgrade is a few seconds of downtime.

**Backups.** Back up three things together: the Gitea volume
(`data-<release>-gitea-0`), the database, and the
`<release>-gitea-secrets` Secret. Without `secretKey` from that Secret,
every stored 2FA secret is unreadable. For a consistent single-file
dump:

```bash
kubectl -n gitea exec statefulset/git-gitea -c gitea -- \
  gitea dump --config /etc/gitea/app.ini --file - --type tar.gz > gitea-dump.tar.gz
```

**Uninstalling** keeps the Secret (`helm.sh/resource-policy: keep`) and
the PersistentVolumeClaims. Delete them yourself if you mean it.

**Lost admin 2FA device.** Use the recovery code, or the
`gitea admin user disable-2fa` command added in 28.0.0 (check
`--help` for its flags):

```bash
kubectl -n gitea exec statefulset/git-gitea -c gitea -- \
  gitea --config /etc/gitea/app.ini admin user disable-2fa --username gitea-admin
```

**Moving from the bundled database** to a managed one: `pg_dump` the
bundled database, restore it into the new one, then set
`postgresql.enabled=false` and `externalDatabase.*`.

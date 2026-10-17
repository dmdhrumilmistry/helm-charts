# mailserver

A self-hosted mail server for Kubernetes, built for IPv6 and dual-stack
clusters, using [docker-mailserver](https://github.com/docker-mailserver/docker-mailserver)
(DMS): Postfix, Dovecot, Rspamd, Fail2ban and postscreen in one pod,
every one of them open source. ClamAV is available but off by default.

The chart has one required value, `domain`. The hostname, postmaster
address, default accounts and aliases, DKIM signing domain, TLS
certificate and the DNS records it prints for you all derive from it.
Nothing in the chart names a real domain, so a values file is the only
place yours needs to live.

- [Install](#install)
- [Ports](#ports) - what to open, in which direction, and why
- [IPv6](#ipv6)
- [DNS records](#dns-records)
- [Security tooling](#security-tooling)
- [Accounts and aliases](#accounts-and-aliases)
- [TLS](#tls)
- [Webmail](#webmail)
- [Publishing DNS records](#publishing-dns-records)
- [Values](#values)
- [Operating it](#operating-it)

## Install

Prerequisites:

- A cluster that can hand the mail Service a public IPv6 address
  (dual-stack or IPv6-only, plus a LoadBalancer implementation such as
  MetalLB or a cloud LB), or a node with a public IPv6 address for
  [host networking](#host-networking).
- [cert-manager](https://cert-manager.io) with a **DNS-01** issuer, or
  an existing TLS Secret for the mail hostname.
- Control over the domain's DNS zone, and over the PTR (reverse DNS)
  record of the IPv6 address you will send from.

```bash
helm install mail dmdhrumilmistry/mailserver \
  --namespace mail --create-namespace \
  --set domain=example.com \
  --set tls.certManager.issuerRef.name=letsencrypt-dns
```

Keep site-specific values out of version control: either pass them with
`--set`, or put them in a file matching `*-test-values.yaml`, which this
repository already ignores.

```bash
helm install mail dmdhrumilmistry/mailserver -n mail --create-namespace \
  -f mail-test-values.yaml
```

Then follow the printed notes: wait for the certificate, read the DNS
records (with your DKIM key filled in) from the init container's log,
create them, and run `helm test`.

## Ports

Give this table to whoever owns the firewall, security groups and load
balancer. "Inbound" means from the internet to the mail Service address
(or the node, with host networking); "outbound" means from the pod or
node to the internet.

### Inbound

| Port | Proto | Who connects | Default | Why |
|---|---|---|---|---|
| **25** | TCP | Other mail servers (Gmail, Outlook, ...) | **Required**, always on | SMTP relay between servers. Every message sent to your domain arrives here, found through your MX record. Must be reachable over IPv6 if you publish an AAAA record. Encrypted with STARTTLS; sending servers never use 465/587. |
| **465** | TCP | Your users' mail clients | On (`ports.submissions`) | Submission over implicit TLS (RFC 8314). How clients *send* mail. Requires a login. The recommended client port. |
| **587** | TCP | Your users' mail clients | On (`ports.submission`) | Submission over STARTTLS. Same as 465 for clients that cannot do implicit TLS. Some networks block 465, so keep both unless you know your clients. |
| **993** | TCP | Your users' mail clients | On (`ports.imaps`) | IMAP over implicit TLS. How clients *read* mail. |
| 143 | TCP | Mail clients | Off (`ports.imap`) | IMAP over STARTTLS. Redundant with 993 for every modern client. |
| 995 | TCP | Mail clients | Off (`ports.pop3s`) | POP3 over implicit TLS. Only if you have POP3 clients. |
| 4190 | TCP | Mail clients | Off (`ports.managesieve`) | ManageSieve, for editing server-side filter rules from a client. |
| 443 | TCP | Your users' browsers | On (`webmail.enabled`) | HTTPS for `webmail.<domain>`. Goes to your **HTTP ingress controller**, not the mail Service. |
| 443 | TCP | Other mail servers | Only with `mtaSts.enabled` | HTTPS for `mta-sts.<domain>`, serving the MTA-STS policy. This goes to your **HTTP ingress controller**, not the mail Service. |
| 80 / 443 | TCP | Let's Encrypt | Only with an HTTP-01 issuer | ACME challenges. Not needed with the recommended DNS-01 issuer. |

Ports 25, 465, 587 and 993 are what a typical deployment opens. Port 25
accepts no logins at all; 465 and 587 accept them only inside TLS, and
Dovecot refuses cleartext logins, so no port ever carries a password
unencrypted. Nothing needs 110 (plain POP3).

### Outbound

| Port | Proto | Destination | Why |
|---|---|---|---|
| **25** | TCP | Any address | Delivering mail to other servers. **Many clouds block this by default**: GCP blocks it outright, AWS and Azure throttle or block it until you file a request. Without it you can receive but not send; see [relaying](#if-outbound-25-is-blocked). |
| 53 | UDP, TCP | Your resolvers | MX, SPF, DKIM, DMARC, MTA-STS and blocklist lookups. TCP is needed too: DKIM and DNSSEC answers often exceed UDP limits. |
| 443 | TCP | Internet | Rspamd map updates, fetching other domains' MTA-STS policies, and ClamAV signature updates (`database.clamav.net`) if you enable it. |

### ICMPv6

Allow ICMPv6, at least types 1 (destination unreachable), 2 (packet too
big), 3 (time exceeded) and 4 (parameter problem), plus neighbour
discovery (133-137) on the node's link. IPv6 routers never fragment,
so they rely on "packet too big" for path MTU discovery. Block it and
small packets still get through, but large ones such as TLS handshakes
carrying a certificate chain stall. The symptom is connections that
open fine and then hang.

### Internal only

These listen inside the pod and must not be published. The chart's
NetworkPolicy (`networkPolicy.enabled`, on by default) admits only the
ports in the inbound table above.

| Port | What |
|---|---|
| 11334 | Rspamd web controller and API. Binds every pod interface, so the NetworkPolicy is what keeps it private; with `network.hostNetwork` the chart binds it to loopback instead. Reach it with `kubectl port-forward`. |
| 11332, 11333 | Rspamd milter and scanner workers (localhost only). |
| 6379 | Redis for Rspamd (localhost only). |

## IPv6

Mail punishes IPv6 mistakes harder than IPv4 ones: Gmail and Microsoft
reject IPv6 senders outright unless the address has a matching PTR
record and passes SPF or DKIM. Work through this list.

### 1. The Service gets an IPv6 address

`network.ipFamilyPolicy` and `network.ipFamilies` set the Service's
address families:

```yaml
network:
  # Default: IPv6 wherever the cluster supports it, still installs on
  # IPv4-only clusters.
  ipFamilyPolicy: PreferDualStack
  ipFamilies: []

  # IPv6 only:
  # ipFamilyPolicy: SingleStack
  # ipFamilies: [IPv6]

  # Both, IPv6 primary:
  # ipFamilyPolicy: RequireDualStack
  # ipFamilies: [IPv6, IPv4]
```

The cluster itself must be dual-stack or IPv6, and the LoadBalancer
implementation must hand out IPv6 addresses (MetalLB: an IPv6
`IPAddressPool`; clouds: usually an annotation, set it under
`service.annotations`).

An IPv6-only server cannot receive mail from the many senders that
still have no IPv6. Publish an A record too if you can.

### 2. The real client address reaches the pod

`service.externalTrafficPolicy: Local` (the default) keeps the client's
address. Without it, connections appear to come from a node: SPF checks
fail, blocklist lookups query the wrong address, and Fail2ban bans the
node. If you need an L4 proxy in front, it must speak the PROXY
protocol; see the [upstream guide](https://docker-mailserver.github.io/docker-mailserver/latest/config/advanced/kubernetes/#using-the-proxy-protocol).

### 3. Outbound mail leaves from an address you control

Receivers check the address mail comes *from*, which is not
necessarily the Service address mail arrives at. With pod networking,
outbound traffic leaves through the node, usually masqueraded to the
node's IPv6 address. That address needs:

- a PTR record resolving to the mail hostname, and
- a place in SPF: `v=spf1 mx ip6:<egress address> -all`.

Find it by sending a message to a Gmail address and reading the
`Received:` header, or with
`kubectl exec <pod> -- curl -6 -s https://ifconfig.co`.

If that address has no PTR yet, set `network.outboundAddressPreference:
ipv4` so Postfix delivers over IPv4 until it does.

### Host networking

```yaml
network:
  hostNetwork: true
  hostInterface: ens33              # the node's main interface
  smtpBindAddress6: "2001:db8::25"   # the address your PTR and SPF cover
service:
  type: ClusterIP
nodeSelector:
  kubernetes.io/hostname: mail-node
```

The pod uses the node's network stack directly, so the real client
address arrives without any Service tricks, and outbound mail leaves
from an address you pin with `smtpBindAddress6`. Pinning matters: Linux
hosts often carry several IPv6 addresses (including temporary privacy
addresses), and Postfix would otherwise pick one per connection. The
cost is that mail is tied to one node, the NetworkPolicy no longer
applies, and Fail2ban bans land in the node's firewall.

Every port DMS listens on is then open on the node, including 143
(IMAP with STARTTLS, which DMS always enables); `ports.*` only shapes
the Service. Logins on 143 still require TLS, but close it at the node
or router firewall if you want the surface to match the
[port table](#ports). The chart binds Rspamd's controller to loopback
in this mode so 11334 never reaches the node's public addresses.

`network.hostInterface` is required in this mode: docker-mailserver
reads its own address from that interface and assumes `eth0`
otherwise.

### If outbound 25 is blocked

Relay through a provider that accepts submissions on 587:

```yaml
extraEnv:
  DEFAULT_RELAY_HOST: "[smtp.relay.example]:587"
  RELAY_USER: "user"
  RELAY_PASSWORD: "password"   # prefer a Secret-backed values file
```

SPF must then include the relay provider instead of (or as well as) your
own address.

## DNS records

The init container prints the full set for your domain, including the
DKIM public key:

```bash
kubectl logs -n mail mail-mailserver-0 -c init-config
```

For `domain=example.com`:

| Name | Type | Value | Why |
|---|---|---|---|
| `mail.example.com` | AAAA | the Service's IPv6 | Where the mail host is. Add an A record too for IPv4 senders. |
| `example.com` | MX | `10 mail.example.com.` | Where mail for the domain goes. |
| `example.com` | TXT | `v=spf1 mx -all` | Which addresses may send for the domain. Add `ip6:` for your egress address if it differs. |
| `webmail.example.com` | AAAA / A | your HTTP ingress | With `webmail.enabled`: the browser inbox. |
| `mail._domainkey.example.com` | TXT | `v=DKIM1; k=rsa; p=...` | Public key that verifies the DKIM signature on outbound mail. |
| `_dmarc.example.com` | TXT | `v=DMARC1; p=none; rua=mailto:dmarc-reports@example.com` | What receivers do when SPF and DKIM fail, and where to send reports. Tighten to `quarantine`, then `reject`. |
| `_smtp._tls.example.com` | TXT | `v=TLSRPTv1; rua=mailto:tls-reports@example.com` | Where senders report TLS failures delivering to you. |
| `_mta-sts.example.com` | TXT | `v=STSv1; id=...` | With `mtaSts.enabled`: announces the policy. The id changes when the policy does. |
| `mta-sts.example.com` | AAAA | your HTTP ingress | With `mtaSts.enabled`: serves the policy. |
| *the IPv6 address* | PTR | `mail.example.com.` | Reverse DNS. Set by whoever owns the address block (cloud console or hosting provider), not in your zone. |

A 4096-bit DKIM key is longer than one 255-character TXT string. Most
DNS providers split it for you; if yours does not, split the value into
several quoted strings in one record.

## Security tooling

All on by default unless noted.

| Tool | What it does | Value |
|---|---|---|
| **Rspamd** | Spam scoring, Bayes learning from the Junk folder, DKIM signing of outbound mail, SPF, DKIM, DMARC and ARC checks on inbound mail. Replaces the older OpenDKIM/OpenDMARC/SpamAssassin/Amavis stack, which the chart turns off. | `security.rspamd` |
| **ClamAV** | Rejects mail carrying known malware. **Off**: the large senders already scan outbound mail, so it rarely catches anything, and it needs about 1.5 GiB of memory. Raise `resources.limits.memory` to 3Gi if you enable it. | `security.clamav.enabled` |
| **Fail2ban** | Bans addresses after repeated failed logins on SMTP and IMAP. Needs `NET_ADMIN`/`NET_RAW` and the real client address. | `security.fail2ban` |
| **postscreen** | Screens SMTP clients before Postfix talks to them, dropping bots that speak out of turn. | `security.postscreenAction` |
| **DNS blocklists** | postscreen checks Spamhaus and others. **Off**: free tiers refuse queries via public resolvers; enable with `dnsConfig` pointing at your own recursive resolver. | `security.dnsbl` |
| **Greylisting** | Temporarily rejects first-time senders. **Off**: delays legitimate first messages. | `security.rspamd.greylisting` |
| **Spoof protection** | Authenticated users can only send as their own addresses. | `security.spoofProtection` |
| **Outbound MTA-STS** | Refuses to deliver over a downgraded connection to domains that publish a policy. | `security.outboundMtaSts` |
| **Inbound MTA-STS** | Publishes your own policy, so senders refuse to deliver to you without verified TLS. **Off**: needs an HTTP ingress. Start in `testing`. | `mtaSts` |
| **TLS** | TLS 1.2+ with forward secrecy on every port; password logins refused without TLS. | `tls.level` |
| **NetworkPolicy** | Only the published mail ports reach the pod. | `networkPolicy.enabled` |

Also: the DMS container drops all capabilities except those its services
need, uses the runtime default seccomp profile, and mounts no service
account token. The MTA-STS web server runs as non-root on a read-only
root filesystem.

## Accounts and aliases

```yaml
accounts:
  - name: postmaster          # becomes postmaster@<domain>
  - name: alice
    password: ""              # empty: generated, preserved on upgrade
  - name: bob@other.example   # full addresses are kept as-is

aliases:
  - from: abuse
    to: postmaster
  - from: sales
    to: alice
```

Read a generated password:

```bash
kubectl get secret -n mail mail-mailserver-accounts \
  -o go-template='{{index .data "alice_at_example.com" | base64decode}}{{"\n"}}'
```

Passwords are hashed with SHA512-CRYPT (the scheme DMS's own tooling
uses) by the init container on every start. The values list is the
source of truth: accounts added with `setup email add` inside the pod
last until the next restart. To manage hashes yourself, put a
`postfix-accounts.cf` in a Secret and set `existingAccountsSecret`.

If no account or alias is `postmaster@<domain>`, the chart aliases it to
the first account, since RFC 5321 requires it to deliver.

DKIM signing covers `domain` only. Accounts on other domains can send,
but their mail goes out unsigned.

## TLS

The chart needs TLS: give it a cert-manager issuer
(`tls.certManager.issuerRef`) or an existing `kubernetes.io/tls` Secret
(`tls.existingSecret`) covering the hostname.

Use a **DNS-01** issuer. The mail hostname points at the mail Service,
not your HTTP ingress, so an HTTP-01 challenge for it fails.

The certificate is RSA 2048 by default. Some sending servers still
cannot negotiate ECDSA, and they fall back to plaintext rather than
failing. Renewals are picked up by DMS's change detector without a
restart.

## Webmail

[Roundcube](https://roundcube.net) (GPL-3.0), on by default, at
`https://webmail.<domain>` behind your HTTP ingress controller. Users
log in with the bare name (`alice`) or the full address.

- It reaches the mail server inside the cluster over IMAPS (993) and
  SMTPS (465), verifying the mail certificate against the mail hostname,
  so `ports.imaps` and `ports.submissions` must stay on.
- Its TLS certificate comes from the same cert-manager issuer as the
  mail certificate, unless you set `webmail.ingress.tls.secretName`.
- Contacts and settings live in SQLite on a small volume, kept on
  uninstall. Mail itself stays on the mail server.

**Brute force.** Every webmail login reaches Dovecot from the Roundcube
pod, so Fail2ban would ban the webmail for everyone after a few wrong
passwords. The chart therefore tells Fail2ban to ignore
`webmail.clusterNetworks`, and Roundcube rate-limits failed logins
(`webmail.loginRateLimit` per minute) per real client address, read
from the ingress controller's `X-Forwarded-For`. The default
`clusterNetworks` covers every private range; narrow it to your pod CIDR
(`10.42.0.0/16` on k3s) so LAN clients stay subject to Fail2ban.

Turn it off with `webmail.enabled=false`; nothing else depends on it.

## Publishing DNS records

With `dns.publish.enabled`, a CronJob keeps the records from the
[DNS records](#dns-records) table in your zone (Cloudflare for now),
re-checking every 5 minutes. Address records follow your current
address, so a dynamic IPv6 prefix stops being a problem.

```yaml
dns:
  dmarc:
    policy: none          # tighten to quarantine, then reject
  publish:
    enabled: true
    dryRun: true          # first run: log what it would change
    cloudflare:
      apiTokenSecret: cloudflare-api-token   # Zone:DNS:Edit + Zone:Zone:Read
```

Run it once without waiting for the schedule:

```bash
kubectl create job -n mail --from=cronjob/<release>-mailserver-dns dns-now
kubectl logs -n mail job/dns-now
```

It only touches what it owns: the A/AAAA records of the mail and
webmail hostnames, an MX pointing at the mail hostname, and the TXT
records starting `v=spf1`, `v=DKIM1`, `v=DMARC1`, `v=TLSRPTv1` and
`v=STSv1` at their names. Other records, including other MX and TXT
records at the apex, are left alone (other MX records are reported in
the log). Records carry a comment naming the release. Reverse DNS (PTR)
lives with whoever owns the address block and cannot be set from here.

## Mail headers

- **DKIM**: everything your users send is signed (Rspamd, `dkim.selector`).
- **ARC** (`security.rspamd.arc`): mail passing through (forwards, lists)
  is sealed, so the next hop can trust the checks made here even after
  forwarding breaks SPF. Uses the DKIM key; no extra record.
- **Authentication-Results** (`security.rspamd.authenticationResults`):
  inbound mail carries the SPF, DKIM, DMARC and ARC verdicts, without
  naming the logged-in user.
- **Privacy on outbound mail**: the sender's client IP (the submission
  `Received` line), `User-Agent`, `X-Mailer` and `X-Originating-IP` are
  removed, and Rspamd's diagnostic headers are added to inbound mail
  only.

## Values

| Key | Default | Description |
|---|---|---|
| `domain` | `""` | **Required.** The domain you receive mail for. |
| `hostname` | `mail.<domain>` | The server's name: MX target, certificate name, SMTP greeting, PTR target. |
| `postmasterAddress` | `postmaster@<domain>` | Receives bounces and reports. |
| `accounts` | `[{name: postmaster}]` | Mailboxes. Passwords generated when empty. |
| `existingAccountsSecret` | `""` | Secret with your own `postfix-accounts.cf`. |
| `aliases` | abuse, dmarc-reports, tls-reports to postmaster | Extra addresses. |
| `network.ipFamilyPolicy` | `PreferDualStack` | Service address family policy. |
| `network.ipFamilies` | `[]` | Service address families, e.g. `[IPv6]`. |
| `network.inetProtocols` | `all` | What Postfix and Dovecot listen on: `all`, `ipv4`, `ipv6`. |
| `network.outboundAddressPreference` | `any` | Family Postfix tries first for delivery. |
| `network.smtpBindAddress6` | `""` | Source IPv6 for outbound mail (host networking). |
| `network.hostNetwork` | `false` | Use the node's network stack. |
| `network.hostInterface` | `""` | Required with `hostNetwork`: the node's main interface. |
| `ports.*` | 465, 587, 993 on | Which client ports to publish. 25 is always on. |
| `service.type` | `LoadBalancer` | |
| `service.externalTrafficPolicy` | `Local` | Keep it `Local`. |
| `service.annotations` | `{}` | LB address pools, cloud IPv6 settings. |
| `tls.certManager.issuerRef.name` | `""` | Required unless `tls.existingSecret` is set. |
| `tls.existingSecret` | `""` | Existing TLS Secret for the hostname. |
| `tls.level` | `modern` | `modern` or `intermediate`. |
| `security.*` | see [Security tooling](#security-tooling) | |
| `dkim.selector` | `mail` | DKIM selector. |
| `dkim.existingSecret` | `""` | Bring your own DKIM private key. |
| `webmail.enabled` | `true` | Roundcube webmail. |
| `webmail.host` | `webmail.<domain>` | Webmail hostname. |
| `webmail.clusterNetworks` | private ranges | Trusted proxies, never banned by Fail2ban. Narrow to your pod CIDR. |
| `webmail.ingress.className` | `""` | Ingress class; empty uses the cluster default. |
| `security.fail2ban.ignoreNetworks` | `[]` | Extra addresses Fail2ban never bans. |
| `dns.dmarc.policy` | `none` | `none`, `quarantine` or `reject`. |
| `dns.dmarc.alignment` | `relaxed` | `relaxed` or `strict`. |
| `dns.spf.extraMechanisms` | `[]` | e.g. `include:` a relay provider. |
| `dns.publish.enabled` | `false` | Keep the records in your zone with a CronJob. |
| `dns.publish.cloudflare.apiTokenSecret` | `""` | Required with `dns.publish.enabled`. |
| `dns.publish.dryRun` | `false` | Log changes without making them. |
| `security.rspamd.arc` | `true` | ARC-seal mail passing through. |
| `security.rspamd.authenticationResults` | `true` | Add Authentication-Results to inbound mail. |
| `mtaSts.enabled` | `false` | Publish an inbound MTA-STS policy. |
| `mtaSts.mode` | `testing` | `testing`, `enforce` or `none`. |
| `postfix.extraMainCf` | `""` | Extra Postfix `main.cf` lines. |
| `dovecot.extraConfig` | `""` | Extra Dovecot config (2.4 syntax). |
| `extraEnv` | `{}` | Any other [DMS environment variable](https://docker-mailserver.github.io/docker-mailserver/latest/config/environment/). |
| `persistence.size` | `20Gi` | Mailboxes, queue, Rspamd state, logs. |
| `resources` | 512Mi request, 1Gi limit | Raise the limit to 3Gi with ClamAV on. |
| `networkPolicy.enabled` | `true` | Admit only the published ports. |
| `dnsPolicy`, `dnsConfig` | | Point Rspamd at your own resolver. |

## Operating it

- **Logs:** `kubectl logs -n mail mail-mailserver-0 -c mailserver`.
- **Rspamd UI:** `kubectl port-forward -n mail mail-mailserver-0 11334`,
  then http://localhost:11334.
- **Queue:** `kubectl exec -n mail mail-mailserver-0 -- postqueue -p`.
- **Fail2ban:** `kubectl exec -n mail mail-mailserver-0 -- setup fail2ban`.
- **Back up** the `<release>-dkim` Secret and the data volume. The DKIM
  Secret is kept on `helm uninstall`; losing it means publishing a new
  key, and mail signed with the old one fails verification until DNS
  catches up.
- **Configuration changes** restart the pod: config is rebuilt from
  values on every start, never edited in place.
- **One replica only.** Two Postfix instances on one queue corrupt it.

## Licensing

This chart is MIT. docker-mailserver is MIT, Roundcube is GPL-3.0; the components it bundles
are open source under their own licences (Postfix: IPL/EPL, Dovecot:
MIT/LGPL, Rspamd: Apache-2.0, ClamAV: GPL-2.0, Fail2ban: GPL-2.0). The
chart contains none of their code and references the published image.

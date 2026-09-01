# The gate: Cloudflare Tunnel + Access in front of a loopback origin

The **shared, origin-agnostic** half of this template — the Cloudflare Access gate that fronts a
loopback-bound origin. It is identical whether that origin is `nginx-static` or any other base
server, which is why it lives here once rather than per-server. Nothing here logs into Cloudflare
for you — the dashboard/API steps are yours to run; this is the exact path.

Everything below uses `<PLACEHOLDERS>` — there are no real hostnames, IPs, zone IDs, tunnel UUIDs,
account emails, or AUD tags in this repo (it's public). Fill them in from your own account.

Two tunnel styles exist and the DNS/ingress steps differ between them:

- **Remotely-managed tunnel** (token-installed; ingress config lives in Cloudflare, edited via the
  API) — covered here. No local `config.yml`, no `cloudflared tunnel route dns`.
- **Locally-managed tunnel** (a local `config.yml` + `cloudflared tunnel route dns`) — a different
  path with a cross-zone `cert.pem` gotcha; not covered here. If that's your setup, follow that
  variant's runbook instead.

---

## 0. Prerequisite: your base server is up on loopback

Before the gate goes in front of anything, your chosen base server must already be running as a
Dockge stack under `/opt/stacks/<app>/`, bound to **`127.0.0.1:<HOST_PORT>` only** — see
[`../servers/<your-server>/README.md`](../servers/) (e.g.
[`nginx-static`](../servers/nginx-static/)) for that half. The rest of this runbook assumes it
answers on loopback:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<HOST_PORT>/          # 200
ss -ltnp | grep <HOST_PORT>                                                     # bound 127.0.0.1, NOT 0.0.0.0
```

A `0.0.0.0` bind means the origin is on the LAN with no auth — stop and fix it before going
further. The loopback bind is the security floor this gate sits in front of.

---

## 1. Cloudflare — Access app, tunnel ingress, DNS

Order matters: **create the Access app BEFORE the DNS route goes live**, so the hostname is never
reachable without a policy in front of it.

### 1a. Access application

Create a self-hosted Access app whose destination is your hostname. Reuse an existing allow
policy (and, if you have one, a service-token policy for machine probes) by referencing it by
`id` rather than creating a duplicate — confirm real reuse by checking the returned policy's
`created_at` is the ORIGINAL timestamp, not a fresh one.

**One app can cover multiple hostnames, including across two DNS zones** — a `destinations[]`
entry of `type: "public"` is just `{ type, uri }`, a bare hostname with no zone field; Access apps
are account-scoped, not zone-scoped. Before relying on a multi-domain app, **verify the
`destinations` shape against a real existing app** (read one back via the API) rather than trusting
the schema alone. The proven fallback is two single-hostname apps sharing the same policies.

Capture the app's **AUD tag** from the create response — the tunnel ingress rule needs it.

### 1b. Tunnel ingress (remotely-managed)

The tunnel's ingress config is edited via `PUT
/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations`. **This replaces the whole ingress
array**, so include every existing rule plus your new one(s), catch-all last:

```jsonc
{
  "config": {
    "ingress": [
      // ...every EXISTING rule, preserved verbatim...
      {
        "hostname": "<your-hostname>",
        "service": "http://127.0.0.1:<HOST_PORT>",
        "originRequest": {
          "access": { "required": true, "teamName": "<team>", "audTag": ["<your app's AUD>"] },
          "httpHostHeader": "<your-hostname>"
        }
      },
      { "service": "http_status:404" }   // catch-all MUST stay last
    ]
  }
}
```

Each hostname rule carries its **own** `originRequest.access` block. A copy at the config's top
level validates but is **silently ignored** by cloudflared — a per-rule block is mandatory.

### 1c. DNS

Create a **proxied** CNAME per hostname (one per zone), pointing at the tunnel:

```jsonc
// POST /zones/{zone_id}/dns_records
{ "type": "CNAME", "name": "<your-hostname>",
  "content": "<tunnel-id>.cfargotunnel.com", "proxied": true, "ttl": 1 }
```

Use the API even for a remotely-managed tunnel (the `cloudflared tunnel route dns` CLI is only for
the locally-managed style, and has a cross-zone `cert.pem` trap).

---

## 2. Verify — the closed-door probe

From an unauthenticated session (no Access cookie), every hostname must redirect to login:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-hostname>/    # 302
```

A `302` (Location → `<team>.cloudflareaccess.com/cdn-cgi/access/login/<hostname>?...`) is the door
shut. **A `200` unauthenticated is a failed rollout — stop and fix.** Inspect the `Location`
header and confirm the login URL names *your* hostname and the `kid` matches *your* app's AUD, so
you know it's gating the right app, not just returning some generic redirect. Then open the URL in
a real browser and confirm an allow-listed login reaches the site.

---

## 3. Updating the gate

- **Access policy / who gets in** — the Cloudflare Zero Trust dashboard or API; nothing in the
  repo.
- **Adding another hostname to an existing app** — re-PUT the tunnel config with the new ingress
  rule (full-array replace, §1b) and add its DNS record (§1c); add the hostname to the Access app's
  `destinations`.

(Updating the *content or config of the origin itself* — new site files, an `nginx.conf` change —
is the base server's concern, not the gate's: see your server's README, e.g.
[`../servers/nginx-static/README.md`](../servers/nginx-static/README.md).)

## Removing the gate

Remove the tunnel ingress rule, the DNS record, and the Access app via the API/dashboard. Bringing
the origin container down is the base server's concern (its README). The gate holds no state — it's
all Cloudflare-side config plus the loopback bind.

## See also

- The repo-root [`../README.md`](../README.md) — the one-gate-many-servers model and how to pick a
  base server.
- roshne's `Tooling` repo (private) carries the worked examples this runbook generalizes
  (`docs/web-app-remote-access.md` for the locally-managed-tunnel variant, and per-app worked
  examples) — for the maintainer's reference; not needed to use this template.

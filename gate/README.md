# The gate: Cloudflare Tunnel + Access in front of a loopback origin

The **shared, origin-agnostic** half of this template — the Cloudflare Access gate that fronts a
loopback-bound origin. It is identical whether that origin is `nginx-static` or any other base
server, which is why it lives here once rather than per-server. Nothing here logs into Cloudflare
for you — the dashboard/API steps are yours to run; this is the exact path.

Everything below uses `<PLACEHOLDERS>` — no real hostnames, IPs, zone IDs, tunnel UUIDs, account
emails, or AUD tags are committed anywhere in this repo (it's public). Fill them in from your own
account. (Consumer **repo** names do appear throughout — those are provenance citations, not
infrastructure identifiers.)

Two tunnel styles exist and the DNS/ingress steps differ between them:

- **Remotely-managed tunnel** (token-installed; ingress config lives in Cloudflare, edited via the
  API) — covered here. No local `config.yml`, no `cloudflared tunnel route dns`.
- **Locally-managed tunnel** (a local `config.yml` + `cloudflared tunnel route dns`) — a different
  path with a cross-zone `cert.pem` gotcha; not covered here. If that's your setup, see Cloudflare's
  public local-management docs:
  <https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/local-management/>

---

## 0. Check the origin answers on loopback, and only on loopback

The gate asks one thing of the origin: **something answers on `127.0.0.1:<HOST_PORT>`, and nothing
answers from anywhere else.** How that process got there — a container, a systemd service, a bare
process — is your base server's business, not the gate's; see
[`../servers/<your-server>/README.md`](../servers/) (e.g.
[`nginx-static`](../servers/nginx-static/)) for that half. Bring it up there, then verify the bind
here — this check belongs to the gate, because that bind is the security floor the gate sits in
front of:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<HOST_PORT>/          # 200
ss -ltnp 'sport = :<HOST_PORT>'                                                 # exact port; expect one line bound 127.0.0.1, NOT 0.0.0.0
docker port <app> 2>/dev/null                                                   # cross-check (container origins): "80/tcp -> 127.0.0.1:<HOST_PORT>"
docker version --format '{{.Server.Version}}'                                   # >= 28.0.0 if a Docker container publishes the port
```

Use `ss`'s exact `sport =` filter, not `grep <HOST_PORT>` — a substring grep also matches `:8080`,
`:18080`, or a `pid=<HOST_PORT>` on an unrelated socket, so on a busy box the one line that matters
is buried or a foreign match triggers a false alarm. **Empty output is not a pass** — it means the
origin isn't up or you have the wrong port. A `0.0.0.0` bind means the origin is on the LAN with no
auth — stop and fix it before going further.

**A loopback publish is the security floor only on Docker Engine >= 28.0.0.** If a Docker container
publishes the port (as `nginx-static` does), a clean `ss` showing `127.0.0.1` is not the whole story
on an older engine: Docker's docs state that "[i]n releases older than 28.0.0, hosts within the same
L2 segment (for example, hosts connected to the same network switch) can reach ports published to
localhost" — the nat DNAT rule rewrites the destination before the kernel's martian check, so a LAN
neighbour that routes `127.0.0.1` via the box reaches the container behind the gate. Engine 28.0.0
fixed it ("Fix a security issue that was allowing neighbor hosts to connect to ports mapped on a
loopback address", moby/moby#49325; the long-standing report is moby/moby#45610). There is no 27.x
backport, and distro-packaged engines often lag well behind — check `docker version` (Server
component) rather than assuming. This is Docker-specific; an origin that is a bare systemd process
binding `127.0.0.1` is not affected.

Run these from a shell **on the box**. If you later add an automated liveness probe that runs from
*another container*, it cannot reach a loopback-scoped Docker publish at all: the DNAT match is
destination-scoped to `127.0.0.1`, so a probe aimed at a bridge gateway such as `172.17.0.1` fails
against a perfectly healthy origin (`Tooling#283`).

---

## 1. Cloudflare — Access app, tunnel ingress, DNS

Order matters: **create the Access app BEFORE the DNS route goes live**, so the hostname is never
reachable without a policy in front of it.

### 1a. Access application

Create a self-hosted Access app whose destination is your hostname, via `POST
/accounts/{account_id}/access/apps`. Reuse an existing allow policy (and, if you have one, a
service-token policy for machine probes) by referencing it by `id` rather than creating a
duplicate — confirm real reuse by checking the returned policy's `created_at` is the ORIGINAL
timestamp, not a fresh one.

```jsonc
{
  "name": "<app-name>",
  "type": "self_hosted",
  "destinations": [
    { "type": "public", "uri": "<your-hostname>" }
  ],
  "session_duration": "24h",
  // Which login methods this app offers. Leaving these two OUT is a decision, not a
  // no-op -- see "Pin your login method" below.
  "allowed_idps": ["<your-idp-id>"],
  "auto_redirect_to_identity": true,
  "policies": [
    { "id": "<existing-allow-policy-id>" }   // reuse by id; don't duplicate
  ]
}
```

Capture the app's **AUD tag** from the create response — the tunnel ingress rule needs it.

(Cloudflare's schema still marks the older `domain` field required, but `destinations` supersedes
it and a create with `destinations` alone is what the reference rollout used. If you validate the
body against the raw schema, expect a spurious "missing `domain`".)

**Pin your login method — or decide not to, on purpose.** Omit `allowed_idps` and Cloudflare
defaults it to *every* identity provider configured on your account; omit
`auto_redirect_to_identity` and it defaults to `false`, showing an IdP picker. Usually it is your
Allow policy, not these fields, that grants access — but they set *how* an allow-listed person may
authenticate, so if your account carries providers of differing strength, the weakest one an
allow-listed user can reach is the real bar, whatever you thought was in force.

They stop being merely cosmetic the moment a policy rule keys on **IdP group membership**: Access
only evaluates a user's IdP group memberships when they actually authenticated through that IdP, so
someone who logs in by another method is no longer matched by such a rule. An `Exclude` rule built
on an IdP group therefore stops excluding, and fails open. Pin `allowed_idps` if any of your rules
work that way.

- **List the providers on your account first** (`GET /accounts/{account_id}/access/identity_providers`)
  rather than assuming. What you find depends on when the account was made: Cloudflare made its own
  IdP the default for Zero Trust organizations created from mid-2026, and stopped adding one-time
  PIN automatically; older organizations keep whatever they were set up with, OTP included. Adding
  OTP later is also a supported choice, so an account can have both.
- **The two fields are coupled**: Cloudflare documents that `auto_redirect_to_identity` requires
  exactly one entry in `allowed_idps`. What happens if you break that rule is **untested here** —
  expect either a rejected request or the picker you were trying to skip; don't rely on either.
- **Later updates are a full replace.** The app endpoint has `PUT` and no `PATCH`, so a
  subsequent update that omits these fields silently resets them to the defaults above. Re-send the
  whole body, not just the parts you meant to change — the same trap as the tunnel config in §1b.

**One app can cover multiple hostnames, including across two DNS zones** — a `destinations[]`
entry of `type: "public"` is just `{ type, uri }`, a bare hostname with no zone field; Access apps
are account-scoped, not zone-scoped. `Tooling#282` proved exactly this — one two-zone app, created
first and read back clean on the first attempt, so the two-single-hostname-app split was never
needed. Still **read the `destinations` shape back via the API** to confirm your own; the
alternative, if you ever hit a case the single app can't cover, is two single-hostname apps sharing
the same policies.

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
level validates but is **silently ignored** by cloudflared — a per-rule block is mandatory. The
closed-door probe in §2 can't confirm it: that 302 comes from the edge Access policy on the
hostname, not from the origin-side JWT check this block turns on, so a config missing the block (or
with it only at top level) still returns 302 with every verify step green. Read the config back and
confirm each rule carries it: `GET /accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations`,
and check the hostname rule's `originRequest.access.required` is `true` with your app's AUD.

### 1c. DNS

Create a **proxied** CNAME per hostname (one per zone), pointing at the tunnel:

```jsonc
// POST /zones/{zone_id}/dns_records
{ "type": "CNAME", "name": "<your-hostname>",
  "content": "<tunnel-id>.cfargotunnel.com", "proxied": true, "ttl": 1 }
```

Use the API even for a remotely-managed tunnel: `cloudflared tunnel route dns` needs a `cert.pem`
from `cloudflared tunnel login` (a token-installed box has none) and carries a cross-zone `cert.pem`
trap, so the API is the reliable path either way. (The CLI works regardless of how the tunnel is
managed — the blocker is the missing `cert.pem`, not the management style.)

---

## 2. Verify — the closed-door probe

From an unauthenticated session (no Access cookie), every hostname must redirect to login:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-hostname>/    # 302
```

A `302` (Location → `<team>.cloudflareaccess.com/cdn-cgi/access/login/<your-hostname>?...`) is the door
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
  `destinations` (also a full replace, §1a).

(Updating the *content or config of the origin itself* is the base server's concern, not the
gate's — including whether a given change needs the origin restarted: see your server's README,
e.g. [`../servers/nginx-static/README.md`](../servers/nginx-static/README.md).)

## Removing the gate

Remove the tunnel ingress rule, the DNS record, and the Access app via the API/dashboard. Shutting
the origin itself down is the base server's concern (its README). The gate holds no state — it's
all Cloudflare-side config plus the loopback bind.

## See also

- The repo-root [`../README.md`](../README.md) — the one-gate-many-servers model and how to pick a
  base server.
- The maintainer's `Rackbops/Tooling` repo (private) carries the worked examples this runbook generalizes
  (`docs/web-app-remote-access.md` for the locally-managed-tunnel variant, and per-app worked
  examples) — for the maintainer's reference; not needed to use this template.

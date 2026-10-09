# node-app base server

A **dynamic container app** — a built image running a live process, not stock nginx serving files —
behind the Cloudflare Access gate. Its distinctive parts vs `nginx-static`:

- **A per-app cloudflared token-tunnel sidecar**, in the app's own compose project, instead of the
  box's shared host tunnel. The app publishes **no host port** and is reachable only in-network via
  the sidecar — that no-port bind is the security floor; Access is the door.
- **A restart-on-update story.** nginx re-reads files per request, so it never swaps a container; a
  process must reload code, so a new image means a new container. `publish/deploy-pull.sh` does the
  swap: `docker login` → `docker compose pull` → recreate **only when the running container isn't
  already on the tag's image** ([#108](https://github.com/Rackbops/rackbops-web-deploy-template/issues/108):
  not "only when the digest moved" — a recreate that itself failed leaves that mismatch in place, so
  the next poll retries it even though the tag's own digest hasn't changed since). The app **never
  pulls itself** (design §10's 53k-crash-loop lesson) — an external one-shot timer does.

**Reference consumer: `artifact-console`** — image `ghcr.io/rackbops/artifact-console` (private),
container port `8787`, three named volumes `config`/`state`/`store`. The concrete values below use it.

## Files

| File | Goes to | What |
|---|---|---|
| `compose.yaml.example` | `/opt/stacks/<app>/compose.yaml` | the app service (built image, named volumes, no host port) + a `cloudflared` token-tunnel sidecar behind an opt-in `tunnel` profile |
| `.env.example` | `/opt/stacks/<app>/.env` (`chmod 600`) | `IMAGE`/`IMAGE_TAG`, the `REGISTRY_*` pull credential, `CLOUDFLARE_TUNNEL_TOKEN`, app config; **fill in, never commit** |
| `publish/deploy-pull.sh.example` | `/opt/stacks/<app>/deploy/deploy-pull.sh` | the one-shot: login → `compose pull` → compare the running container's image to the tag's → `up -d` on a mismatch |
| `publish/deploy-pull.service.example` | `/etc/systemd/system/<app>-deploy.service` | oneshot system unit, drops to `<user>` (must be in the `docker` group) |
| `publish/deploy-pull.timer.example` | `/etc/systemd/system/<app>-deploy.timer` | polls the registry (`OnBootSec` + `OnUnitActiveSec`) |
| `publish/set-tunnel-token.sh.example` | `/opt/stacks/<app>/deploy/set-tunnel-token.sh` | writes `CLOUDFLARE_TUNNEL_TOKEN` into `.env` from stdin, so the token never touches shell history or an agent's context -- see [The gate](#the-gate--a-per-app-token-tunnel-not-the-shared-host-tunnel) |
| `ci/release.yml.example` | `.github/workflows/release.yml` | build + push the `linux/amd64` image on a `v*` tag |
| `ci/image-ratchet.md` | (adapt, don't copy) | how to build the real image in CI and assert it boots -- see [Building and shipping the image](#building-and-shipping-the-image) |

## Bring it up on the box

Managed as a Dockge stack at `/opt/stacks/<app>/`.

```bash
# 1. Stack dir + files.
sudo mkdir -p /opt/stacks/<app>/deploy && sudo chown "$USER" /opt/stacks/<app> -R
cp compose.yaml.example /opt/stacks/<app>/compose.yaml
cp .env.example         /opt/stacks/<app>/.env      # then fill it in (chmod 600)
cp publish/deploy-pull.sh.example /opt/stacks/<app>/deploy/deploy-pull.sh

# 2. Fill .env: IMAGE (e.g. ghcr.io/rackbops/artifact-console), IMAGE_TAG (latest, or a pinned vX.Y.Z),
#    REGISTRY_USER + REGISTRY_TOKEN (a read:packages PAT for a PRIVATE image), and
#    CLOUDFLARE_TUNNEL_TOKEN (this app's token tunnel from the gate runbook).

# 3. Log in once so the first pull works (deploy-pull.sh also does this each run). ghcr.io is the
#    REGISTRY default; use whatever you set REGISTRY to in .env:
grep '^REGISTRY_TOKEN=' /opt/stacks/<app>/.env | cut -d= -f2- \
  | docker login ghcr.io -u <REGISTRY_USER> --password-stdin

# 4. Bring up the app AND the tunnel sidecar (the `tunnel` profile opts the sidecar in):
cd /opt/stacks/<app> && docker compose --profile tunnel up -d
```

### The gate — a per-app token tunnel, not the shared host tunnel

This tier uses a **per-app token tunnel** (the `cloudflared` sidecar above), which diverges from
[`../../gate/README.md`](../../gate/README.md)'s shared-host-tunnel path in exactly one place — the
tunnel wiring:

- **Tunnel (per-app):** create the tunnel + its token in Cloudflare, put the token in `.env`
  (`CLOUDFLARE_TUNNEL_TOKEN`), and set the tunnel **ingress via the Cloudflare API** to
  `http://<app>:8787` (the compose **service name**, in-network — *not* a published host port), each
  hostname carrying its **own** `originRequest.access` block (a top-level copy is silently ignored).
  - **Getting the token into `.env` without it touching your shell history or an agent's context:**
    pipe it through [`publish/set-tunnel-token.sh.example`](publish/set-tunnel-token.sh.example)
    instead of pasting it into the file by hand.
- **Everything else is identical to `gate/README.md`** — follow it for the **Access app** (capture its
  AUD for the ingress rule), the **proxied CNAME**(s), and the **closed-door verify**
  (unauthenticated → **302** to the Access login, never 200).

> **Skip gate §0's loopback checks.** `gate/README.md` step 0 verifies a *host* loopback bind
> (`curl 127.0.0.1:<PORT>`, `ss -ltnp`). This tier publishes **no host port** — the sidecar reaches
> the app in-network — so there's nothing to `ss` for. Check the origin with
> `docker compose exec <app> wget -qO- http://localhost:8787/healthz` (or just the closed-door 302
> once the tunnel is up) instead.

(This is the same token-sidecar shape `rackbops-ui-ux-std-lib` uses; see `CONTEXT.md` → Known consumers.)

## Variant: a service cloud clients call (no Access app)

**When to use it.** The gate above assumes a human completes an interactive Cloudflare Access
login. Some callers can't: MCP clients (claude.ai, ChatGPT), Claude routines, and scripts running
in a vendor's own cloud have no browser session for Access's login page to redirect. For those,
front the app this way instead of with an Access app.

**What replaces Access:** the service's own bearer-token auth (a 401 with
`WWW-Authenticate: Bearer` otherwise), a Host/Origin allowlist, per-principal limits, and one
Cloudflare rate-limit rule on the hostname. The tunnel sidecar above is still the *only* network
path in — nothing here changes the no-host-port floor, only what stands in for Access on top of
it.

**The rate-limit rule.** A Free-plan zone gets exactly **one** custom WAF rate-limiting rule per
zone (Cloudflare's own plan limit — budget for it accordingly if the zone already uses its one
rule for something else). Its actual shape, read back from a live rule on `mcp.rackbops.com`
(Rackbops/Tooling#758): a rule matching `(http.host eq "<your-hostname>")`, counted by
`cf.colo.id` **and** `ip.src` — so the count is per source IP **per Cloudflare data center**, not
one global counter — over a 10 s period, blocking for 10 s once it trips. That's coarser than a
globally-counted-per-IP rule (the same caller can be counted separately at two different colos),
so treat it as a backstop, not the primary defense — the service's own per-principal limits are
that.

**Trusting a client-IP header.** Reading a header like `cf-connecting-ip` for per-source limits is
safe **only when every path that can reach the app sets it.** Cloudflare's edge sets it, and the
tunnel forwards it unchanged on every request that comes through it — but anything else able to
reach the container (another container sharing a compose network, say) isn't the tunnel and can
send whatever value it likes. If any untrusted path can reach the app, trusting the header lets a
caller forge its way past a per-source limit; otherwise it counts the *whole tunnel* as one source
(the socket peer), which is coarser but never forgeable, until every path in is genuinely trusted.

**Gate differences from `gate/README.md`:** no Access application, and no Access policy — skip
`gate/README.md` §1a entirely, and **§1b's ingress rule loses its `originRequest.access` block
too**, not just the Access app that would have supplied its AUD tag. There's nothing to put in
that block without an Access app, and leaving it in (or leaving a stale AUD in it) would either
error or silently reintroduce the Access-JWT gate this whole variant exists to avoid. The real
ingress rule is just a plain service route, no `access` sub-object at all — the discord-mcp
deployment's actual rule (Rackbops/Tooling#758): `mcp.rackbops.com -> http://discord-mcp:8788`,
with `http_status:404` as the catch-all, nothing else:

```jsonc
{ "hostname": "<your-hostname>", "service": "http://<app>:<CONTAINER_PORT>" }
```

§1c (DNS) and the loopback-check note above are unaffected — apply them as written. Monitor with
Uptime Kuma against an unauthenticated `/healthz` instead of an Access-login env-health probe —
there's no login to probe, and `/healthz` is the one endpoint the app leaves open precisely so a
monitor can reach it without a bearer token.

**Worked example:** Rackbops/discord-mcp, deployed this way at `mcp.rackbops.com`
(Rackbops/Tooling#758) — a public-hostname allowlist, a client-IP-header env var gating the trust
decision above, and a Free-plan rate-limit rule on the hostname exactly as described. Its own
README's "Deploy" section covers the app-specific config; that isn't duplicated here.

**Also required for this variant:** the [Container lockdown](#container-lockdown-recommended)
below.

## Container lockdown (recommended)

Recommended for every `node-app` deploy, and **required** for the no-Access variant above — a
service reachable without an interactive login in front of it should also be the hardest one to
do anything with if it's ever compromised. Add to the app service in `compose.yaml`:

```yaml
services:
  <app>:
    # ...existing image/environment/volumes from compose.yaml.example...
    read_only: true          # the image's own filesystem is never written to
    tmpfs:
      - /tmp                 # writable scratch space a read-only rootfs still needs
    cap_drop:
      - ALL                  # no Linux capability beyond what running as non-root already needs
    security_opt:
      - no-new-privileges:true
    volumes:
      - config:/config:ro    # mount config READ-ONLY -- the app reads it, never writes it
      - state:/state
      - store:/store
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

The same block, minus the `tmpfs` line and the config mount (the sidecar has no `/config` and
doesn't need `/tmp`), applies to the `cloudflared` sidecar too — plus **pin its image tag**
(`cloudflare/cloudflared:20XX.X.X`, never `:latest`). A `:latest` sidecar never gets a fresh pull
on its own: the deploy-pull timer below only ever pulls and recreates the **app** service, so an
unpinned sidecar stays on whatever digest was current the day the stack first came up — no
recurring pull ever revisits it. Pin it, and bump the pin by hand when you want a newer
`cloudflared`.

**Check first.** `read_only: true` fails closed the moment the app writes anywhere it isn't
allowed to — including a place you didn't know it wrote to. Confirm the app writes only to its own
named volumes and `/tmp` *before* flipping this on:

```bash
docker run --rm -it --read-only --tmpfs /tmp <image> <the app's normal command>
```

If it exits complaining about a read-only filesystem somewhere other than a path already covered
by a volume or `/tmp`, that path needs its own volume (or the write needs fixing) before this
block goes in — don't discover it for the first time in production, behind a live gate.

## The deploy-pull timer (image auto-swap)

`publish/deploy-pull.sh` swaps the container when a newer image is published. Its recreate
decision compares the **running container's** image against the tag's image, not a before/after
snapshot of the tag alone -- so a recreate that itself fails (a daemon error, the unit's own
timeout) is retried on the next run instead of being reported "unchanged" forever
([#108](https://github.com/Rackbops/rackbops-web-deploy-template/issues/108)). Since #108, the
timer also restarts a container that is merely **stopped** (a crash, or a deliberate `docker
stop`) -- to keep a service down for maintenance, stop its timer first
(`systemctl stop <app>-deploy.timer`) and start it again afterwards. Install the paired units
once (box side):

```bash
sudo cp publish/deploy-pull.service.example /etc/systemd/system/<app>-deploy.service
sudo cp publish/deploy-pull.timer.example   /etc/systemd/system/<app>-deploy.timer
# edit <app>/<user>/paths in both, then:
sudo systemctl daemon-reload
sudo systemctl enable --now <app>-deploy.timer
```

**Trust note (read this).** UNLIKE nginx-static's privilege-light pull (git + logged reminders, no
docker), this timer **runs docker** (login + `compose pull` + `up -d`), so `<user>` must be in the
`docker` group — **root-equivalent**. Anyone who can publish a new image to `IMAGE:IMAGE_TAG` therefore
gets their image run on the box. Use a pinned `IMAGE_TAG` (not `latest`) if you want a human in the
loop for each version bump.

## Updating

- **New image** (a new tag/digest published) → nothing to do by hand: the timer's next tick pulls it
  and recreates the container (or run `deploy/deploy-pull.sh` yourself). With a moving `:latest` this
  is automatic; with a pinned `IMAGE_TAG` bump `.env` first, then `docker compose up -d`.
- **`compose.yaml`** → `docker compose --profile tunnel up -d`.
- **`.env`** → `docker compose --profile tunnel up -d` (recreates the app **and** the profiled
  cloudflared sidecar; a plain `up -d` wouldn't reach the sidecar, so a changed
  `CLOUDFLARE_TUNNEL_TOKEN` wouldn't apply).
- **A `deploy/*.service`/`*.timer`** → re-copy to `/etc/systemd/system/` + `sudo systemctl daemon-reload`.

## Building and shipping the image

Two pieces live under [`ci/`](ci/), factored out because they're proven CI, not the deploy shape
above: [`release.yml.example`](ci/release.yml.example) (copy-and-fill-`<PLACEHOLDERS>`, builds
and pushes the `linux/amd64` image on a `v*` tag) and [`image-ratchet.md`](ci/image-ratchet.md) (a
pattern to adapt, not a template -- building the real image in CI and asserting it actually boots
catches a class of bug unit tests can't: something the build forgot to `COPY`, a path that only
resolves in dev mode). Both are modeled on `Rackbops/kenzen`'s own workflows -- see `image-ratchet.md`
for why the ratchet itself isn't a drop-in `.yml.example` the way `release.yml` is.

### The Dockerfile itself: corepack is gone as of Node 25

There's no `Dockerfile.example` here -- this tier pulls a published image, it doesn't build one --
but the app repo that produces that image will need a multi-stage `Dockerfile`, and Node dropped
`corepack` from core as of Node 25. The common `RUN corepack enable` (the usual way to get a pinned
`pnpm` before `COPY . .`) fails outright on a `node:25-*`/`node:26-*` build stage --
`corepack: not found`. Install pnpm directly instead, reading the version from `package.json`'s own
`packageManager` field so a pnpm bump keeps flowing through that one field rather than a second pin
in the Dockerfile:

```dockerfile
FROM node:26-alpine AS build
WORKDIR /repo
COPY package.json ./
RUN npm install -g pnpm@"$(node -p "require('./package.json').packageManager.split('@')[1]")"
COPY . .
RUN pnpm install --frozen-lockfile
```

`Rackbops/kenzen`'s own `Dockerfile` is the real, working reference (its `package.json` carries
`"packageManager": "pnpm@X.Y.Z"`). This is the fix from `kenzen#81` / `artifact-console#179` -- both
hit the exact `corepack: not found` build failure moving their base image from `node:24-*` to
`node:26-*`.

## Removing this server

```bash
sudo systemctl disable --now <app>-deploy.timer
sudo rm /etc/systemd/system/<app>-deploy.{service,timer} && sudo systemctl daemon-reload
cd /opt/stacks/<app> && docker compose --profile tunnel down     # add -v to also drop the volumes
```

Then remove the tunnel ingress rule + Access app + DNS in Cloudflare (the gate runbook, in
reverse). **For the [no-Access variant](#variant-a-service-cloud-clients-call-no-access-app):**
there's no Access app to remove -- just the ingress rule and DNS -- and drop the Uptime Kuma
monitor on `/healthz` instead of an env-health Access-login probe.

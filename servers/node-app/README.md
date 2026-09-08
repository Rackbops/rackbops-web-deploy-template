# node-app base server

A **dynamic container app** — a built image running a live process, not stock nginx serving files —
behind the Cloudflare Access gate. Its distinctive parts vs `nginx-static`:

- **A per-app cloudflared token-tunnel sidecar**, in the app's own compose project, instead of the
  box's shared host tunnel. The app publishes **no host port** and is reachable only in-network via
  the sidecar — that no-port bind is the security floor; Access is the door.
- **A restart-on-update story.** nginx re-reads files per request, so it never swaps a container; a
  process must reload code, so a new image means a new container. `publish/deploy-pull.sh` does the
  swap: `docker login` → `docker compose pull` → recreate **only when the image digest moved**. The
  app **never pulls itself** (design §10's 53k-crash-loop lesson) — an external one-shot timer does.

**Reference consumer: `artifact-console`** — image `ghcr.io/rackbops/artifact-console` (private),
container port `8787`, three named volumes `config`/`state`/`store`. The concrete values below use it.

## Files

| File | Goes to | What |
|---|---|---|
| `compose.yaml.example` | `/opt/stacks/<app>/compose.yaml` | the app service (built image, named volumes, no host port) + a `cloudflared` token-tunnel sidecar behind an opt-in `tunnel` profile |
| `.env.example` | `/opt/stacks/<app>/.env` (`chmod 600`) | `IMAGE`/`IMAGE_TAG`, the `REGISTRY_*` pull credential, `CLOUDFLARE_TUNNEL_TOKEN`, app config; **fill in, never commit** |
| `publish/deploy-pull.sh.example` | `/opt/stacks/<app>/deploy/deploy-pull.sh` | the one-shot: login → `compose pull` → digest-diff → `up -d` on change |
| `publish/deploy-pull.service.example` | `/etc/systemd/system/<app>-deploy.service` | oneshot system unit, drops to `<user>` (must be in the `docker` group) |
| `publish/deploy-pull.timer.example` | `/etc/systemd/system/<app>-deploy.timer` | polls the registry (`OnBootSec` + `OnUnitActiveSec`) |
| `ci/release.yml.example` | `.github/workflows/release.yml` | build + push the multi-arch image on a `v*` tag |
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
- **Everything else is identical to `gate/README.md`** — follow it for the **Access app** (capture its
  AUD for the ingress rule), the **proxied CNAME**(s), and the **closed-door verify**
  (unauthenticated → **302** to the Access login, never 200).

> **Skip gate §0's loopback checks.** `gate/README.md` step 0 verifies a *host* loopback bind
> (`curl 127.0.0.1:<PORT>`, `ss -ltnp`). This tier publishes **no host port** — the sidecar reaches
> the app in-network — so there's nothing to `ss` for. Check the origin with
> `docker compose exec <app> wget -qO- http://localhost:8787/healthz` (or just the closed-door 302
> once the tunnel is up) instead.

(This is the same token-sidecar shape `rackbops-ui-ux-std-lib` uses; see `CONTEXT.md` → Known consumers.)

## The deploy-pull timer (image auto-swap)

`publish/deploy-pull.sh` swaps the container when a newer image is published. Install the paired units
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
and pushes the multi-arch image on a `v*` tag) and [`image-ratchet.md`](ci/image-ratchet.md) (a
pattern to adapt, not a template -- building the real image in CI and asserting it actually boots
catches a class of bug unit tests can't: something the build forgot to `COPY`, a path that only
resolves in dev mode). Both are modeled on `Rackbops/kenzen`'s own workflows -- see `image-ratchet.md`
for why the ratchet itself isn't a drop-in `.yml.example` the way `release.yml` is.

## Removing this server

```bash
sudo systemctl disable --now <app>-deploy.timer
sudo rm /etc/systemd/system/<app>-deploy.{service,timer} && sudo systemctl daemon-reload
cd /opt/stacks/<app> && docker compose --profile tunnel down     # add -v to also drop the volumes
```

Then remove the tunnel ingress rule + Access app + DNS in Cloudflare (the gate runbook, in reverse).

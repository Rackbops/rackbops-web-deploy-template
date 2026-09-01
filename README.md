# rackbops-web-deploy-template

A copyable template for deploying a web thing **behind a Cloudflare-Access-gated loopback origin**,
the same way every time. The distinctive, fully-shared spine — a container bound to `127.0.0.1`
only, fronted by a Cloudflare Tunnel + Access so only allow-listed accounts reach it — is
**origin-agnostic**: it's identical whether that loopback port is answered by nginx serving static
files or by an app process. This repo pairs that shared **gate** with pluggable **base servers**.

Copy the pieces you need into a new or existing app repo, fill in the `<PLACEHOLDERS>`, and follow
the two runbooks (the gate, plus your chosen server).

## The model: one gate, many base servers

```
/
  gate/                     # SHARED spine -- the origin-agnostic Cloudflare + loopback + verify runbook
  servers/
    nginx-static/           # base server: stock nginx serving static files  (BUILT)
    (future siblings slot in here -- another static server, or a dynamic app server)
```

- **[`gate/`](gate/)** is the reusable core: the Cloudflare Access app, tunnel ingress, DNS, the
  loopback-bind security floor, and the closed-door verify. Written **once**, used by every base
  server — because it genuinely does not change with the origin (proven identical across the real
  rollouts this was extracted from).
- **[`servers/<name>/`](servers/)** holds only what actually differs per base server: the
  container image, its config, and how new content/code reaches it. Today only
  **[`servers/nginx-static/`](servers/nginx-static/)** exists.

The split point is clean: **everything from "the app binds `127.0.0.1:<port>`" outward is the
shared gate; only how that port is served is per-server.**

## Using it

1. Pick a base server under `servers/` (today: `nginx-static`). Copy its `.example` files into your
   app repo, fill in the placeholders, and follow its `README.md` to get the container up on
   loopback.
2. Follow [`gate/README.md`](gate/README.md) to put the Cloudflare Access gate in front of it.

## Base servers

| Server | Origin | Restart on update? | Status |
|---|---|---|---|
| [`nginx-static`](servers/nginx-static/) | stock `nginx:alpine`, files on a read-only mount | No — nginx re-reads files per request | **Built** (extracted from real consumers) |
| _a second static server_ (e.g. Node `serve`, Caddy) | serves files a different way | varies | Future — add when a real consumer needs it |
| _a dynamic app server_ (Node/Bun/Python process) | a built image / live process | Yes — a process must reload code | Future — different serve/publish, **same gate** |

New servers are added **only when a real consumer needs one** — the tier is left open, not
pre-scaffolded with empty flavors.

## Known consumers

| Consumer | Base server | Publish | Notes |
|---|---|---|---|
| `roshne/Tooling` → `tools-site` | nginx-static | push (scp) | The reference the nginx-static server + gate were extracted from. |
| `roshne/rackbops` (`rackbops.com`) | nginx-static | pull (git timer) | Planned migration onto this template. |
| `roshne/rackbops-ui-ux-std-lib` showcase | nginx-static | tbd | Parked; needs the repo-root web-root knob (sibling `../styles` import). |

## Not in this repo (and where it lives instead)

- **No build tooling / app framework** — bring your own build; a base server just serves its output
  (or runs its process).
- **No app-shell / feature hooks** — the composition-root + route/nav/slot/build-step *hooks* that
  features plug into are a separate, future template, extracted once a second React site exists to
  extract them against. Today they live only in `roshne/Tooling`'s `tools-site` (see its
  `CLAUDE.md`). That's an app-internal concern, orthogonal to this repo's deploy concern.
- **No CI on this repo itself** — the `.example` files are copied and adapted per consumer, who
  owns linting/testing their own copy (as `tools-site` does — its `publish.ps1` is checked by
  `Tooling`'s CI, not by anything here).
- **No real infrastructure IDs** — hostnames, zone/tunnel IDs, AUD tags, and emails live in your
  Cloudflare account and on your box, never committed here.

# rackbops-gated-deploy-template -- verified-facts ledger

The paid-for-once facts behind this template's scaffolds and runbooks. This repo is **derived** --
every scaffold is a genericization of a real, running implementation -- so the ledger's job is to
record *which real thing each piece came from and what was proven about it*, so a future edit
checks against the source instead of re-deriving or inventing. Every entry cites where it was read.

---

## Sources (what each scaffold was extracted from)

- **`roshne/Tooling` `tools-site/`** -- the reference nginx-static consumer (`Tooling#281`). Source
  of `servers/nginx-static/compose.yaml.example`, `nginx.conf.example`, and
  `publish/publish-scp.ps1.example`. The scp publish's stage-then-swap design + `$LASTEXITCODE`
  and empty-build guards were proven and adversarially reviewed there (two review rounds).
- **`roshne/rackbops` `deploy/`** -- the reference git-pull consumer. Source of
  `servers/nginx-static/publish/deploy-pull.{sh,service,timer}.example` (its live
  `git pull --ff-only` on a **systemd system** timer -- installed under `/etc/systemd/system/` via
  `sudo`, running as a system unit that drops to a user via `User=`/`HOME=`; `OnUnitActiveSec=5min`).
- **`roshne/Tooling` `docs/*-remote-access.md`** (private) -- source of `gate/README.md`. The
  Cloudflare Access + tunnel + DNS flow was proven **identical across two origins** in
  `Tooling#282` (one multi-domain Access app fronting a loopback nginx origin), which is the
  evidence that the gate is genuinely origin-agnostic and belongs in one shared place.

Where a scaffold and its source ever diverge, the **source's** proven behavior wins -- re-genericize
from it rather than editing the `.example` free-hand.

---

## Confirmed facts

- **The Cloudflare gate is origin-agnostic** -- verified: the Access app / tunnel ingress / DNS /
  loopback-bind / closed-door-302 flow does not vary with what answers the loopback port. This is
  why `gate/` is shared and `servers/<name>/` holds only the serve/publish delta. (`Tooling#282`.)
- **The two real publish models are push (scp) and pull (git-timer)**, and they are a real fork,
  not cosmetic -- driven by whether the box may hold a repo clone. Both reference nginx-static
  consumers exist and differ on exactly this axis (`tools-site` = push, private repo; `rackbops` =
  pull, clone-as-stack). (`Tooling#281`, `roshne/rackbops`.)
- **A `-p 127.0.0.1:<port>:<port>` publish is NOT reachable via a Docker bridge gateway** -- the
  DNAT is destination-scoped to `127.0.0.1`, so a co-located same-host check must hit loopback, not
  `172.17.0.1`. Relevant if a future server variant wants a co-located liveness check.
  (`Tooling#283`.)

---

## Open questions

- **A second base server's shape** -- probe: when a real consumer needs a non-nginx static server
  or a dynamic app server, extract *its* `servers/<name>/` from that real consumer (not
  speculatively), and decide then whether any publish/serve logic is genuinely shared enough to
  lift out of the per-server dirs.
- **Where the shared gate lives once a dynamic-server variant exists** -- probe: with two real
  server tiers using the same gate, confirm the single shared `gate/` still serves both cleanly, or
  whether anything gate-side needs a per-server hook. No action until that second tier is real.

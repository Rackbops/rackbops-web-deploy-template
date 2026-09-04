# rackbops-web-deploy-template -- verified-facts ledger

The paid-for-once facts behind this template's scaffolds and runbooks. This repo is **derived** --
every scaffold is a genericization of a real, running implementation -- so the ledger's job is to
record *which real thing each piece came from and what was proven about it*, so a future edit
checks against the source instead of re-deriving or inventing. Every entry cites where it was read.

---

## Sources (what each scaffold was extracted from)

All sources are **private** repos in the `Rackbops` org -- cited for provenance, not as something a
reader of this public repo can open. (They moved from the `roshne` user account; the old slugs
still resolve by GitHub's owner redirect, but `Rackbops/...` is canonical.)

- **`Rackbops/Tooling` `tools-site/`** -- the reference nginx-static consumer (`Tooling#281`), and
  the **push (scp)** half of the publish fork. Source of
  `servers/nginx-static/compose.yaml.example`, the `nginx.conf.*.example` pair, and
  `publish/publish-scp.ps1.example`. The scp publish's stage-then-swap design + `$LASTEXITCODE`
  and empty-build guards were proven and adversarially reviewed there (two review rounds).
- **`Rackbops/rackbops` `deploy/`** -- the reference git-pull consumer, and the **pull (git timer)**
  half. Source of `servers/nginx-static/publish/deploy-pull.{sh,service,timer}.example` (its live
  `git pull --ff-only` on a **systemd system** timer, `OnUnitActiveSec=5min`). Why that is a system
  unit rather than a `--user` one is spelled out in the `.service` scaffold's header, and
  summarised in the server README's install section -- not re-derived here.
  Its own bring-up runbook (`DEPLOY.md` steps 1a/1b) is the source for the pull-model clone +
  deploy-key block in the nginx-static README.
- **`Rackbops/Tooling` `docs/*-remote-access.md`** (private) -- source of `gate/README.md`. The
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
  consumers exist and differ on exactly this axis (`tools-site` = push; `rackbops` = pull,
  clone-as-stack). Note both repos are private, so "private repo" is NOT what selects push -- a
  read-only deploy key makes pull work for a private repo, which is exactly what `rackbops` does.
  What selects push is a box that can't or shouldn't hold a clone at all. (`Tooling#281`,
  `Rackbops/rackbops`.)
- **A `-p 127.0.0.1:<port>:<port>` publish is NOT reachable via a Docker bridge gateway** -- the
  DNAT is destination-scoped to `127.0.0.1`, so a co-located same-host check must hit loopback, not
  `172.17.0.1`. Recorded in `gate/README.md` §0 as a caveat for anyone adding an automated probe
  from another container; still the constraint to check first if a future server variant wants a
  co-located liveness check. (`Tooling#283`.)
- **An Access app's `allowed_idps` defaults to every IdP on the account, and `PUT` is a full
  replace** -- omitted fields reset to their defaults, and there is no `PATCH` for them. Both read
  from Cloudflare's OpenAPI schema + docs, 2026-09-02, not from a live account. **Date-sensitive:**
  Cloudflare made its own IdP the default for Zero Trust orgs created from ~2026-06 and stopped
  auto-adding one-time PIN, so what a consumer's account actually carries depends on its age --
  re-check before rewording `gate/README.md` §1a's IdP note.

---

## Known consumers

**Nothing runs the shared `gate/` end-to-end yet.** The two live deployments below are what
`servers/nginx-static/` was *extracted from* -- each still runs its own copy of that code -- and
a third has adopted the repo-root web-root knob but a **different gate** than the one this repo
documents (see its row below). That is why `CLAUDE.md` says only a real consumer standing up a
real box and the *shared* gate proves that piece end-to-end.

| Repo | Base server | Publish | Relationship to this template |
|---|---|---|---|
| `Rackbops/Tooling` -> `tools-site` | nginx-static | push (scp) | **Source.** Live on its own copy; the server + gate were extracted from it. |
| `Rackbops/rackbops` | nginx-static | pull (git timer) | **Source.** Live on its own `deploy/`; migration onto this template is planned, not done. |
| `Rackbops/rackbops-ui-ux-std-lib` showcase | nginx-static | pull (git timer) | **In progress**, `Rackbops/rackbops-ui-ux-std-lib#2`. Confirms the repo-root web-root knob for real (sibling `../styles` import) -- but its gate is `Tooling/docs/per-app-cloudflare-access-tunnel.md`'s **per-app token-sidecar tunnel** (zero published host port; `cloudflared` sidecar in its own compose project), not this repo's shared loopback-bound-port `gate/`. `Tooling`'s own doc calls that pattern out as the right one for a brand-new app-specific endpoint, so this is a deliberate divergence, not a template gap -- see [Open questions](#open-questions). |

**The repo-root web-root knob ships but nobody runs it** -- `compose.yaml.example` and
both `nginx.conf.*.example` variants support it (their deny blocks landed in #19), but it is
inferred from
the sibling-import problem rather than extracted from a running deployment, which is why the server
README flags it as such.

## Open questions

- **A second base server's shape** -- probe: when a real consumer needs a non-nginx static server
  or a dynamic app server, extract *its* `servers/<name>/` from that real consumer (not
  speculatively), and decide then whether any publish/serve logic is genuinely shared enough to
  lift out of the per-server dirs.
- **Where the shared gate lives once a dynamic-server variant exists** -- probe: with two real
  server tiers using the same gate, confirm the single shared `gate/` still serves both cleanly, or
  whether anything gate-side needs a per-server hook. No action until that second tier is real.
- **Should the per-app token-sidecar pattern become a second `gate/` variant here?**
  `rackbops-ui-ux-std-lib` (see Known consumers above) used it instead of this repo's shared
  loopback-bound-port gate, on `Tooling/docs/per-app-cloudflare-access-tunnel.md`'s explicit
  advice that it's the right shape for a brand-new app-specific endpoint (vs. this repo's gate,
  which is right for a stable, already-established shared tool). If a second consumer picks the
  sidecar pattern too, it's a real second gate shape worth extracting here -- same ground-truth
  rule as the base-server tier: extract from a real consumer, not speculatively.

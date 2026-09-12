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
- **`Rackbops/Tooling` `tools-site/worker/`** (`Tooling#638`, given back as `Tooling#661`) --
  source of `workers/file-issue/`: an Access-gated Cloudflare Worker filing/finding a GitHub
  issue in one click. Not an origin server behind the loopback + tunnel gate at all (no loopback
  bind, no tunnel ingress) -- it adds an edge route onto a hostname an app already has gated,
  which is why `workers/` is its own top-level tier, not a `servers/<name>/` entry. Its
  `Sec-Fetch-Site` same-origin check and the `github.ts` GitHub-error-wrapping were both
  adversarially reviewed on the source repo (two review rounds each); its repo-generic design
  (`ALLOWED_REPOS`/`ALLOWED_TITLE_PREFIXES` as Worker vars, never hardcoded) is what makes this
  a real, non-Tooling-specific shape.
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
- **A `-p 127.0.0.1:<HOST_PORT>:<CONTAINER_PORT>` publish is NOT reachable via a Docker bridge gateway** -- the
  DNAT is destination-scoped to `127.0.0.1`, so a co-located same-host check must hit loopback, not
  `172.17.0.1`. Recorded in `gate/README.md` §0 as a caveat for anyone adding an automated probe
  from another container; still the constraint to check first if a future server variant wants a
  co-located liveness check. (`Tooling#283`.)
- **A `127.0.0.1`-published Docker port is the security floor only on Docker Engine >= 28.0.0** --
  the sibling caveat to the DNAT one above, opposite direction. On older engines a host on the same
  L2 segment can reach a loopback-published port even though `ss` shows `127.0.0.1`, because the nat
  DNAT rule rewrites the destination before the martian check; Docker fixed it in 28.0.0
  (`moby/moby#49325`, report `#45610`). Docker-specific -- a bare systemd process binding `127.0.0.1`
  is unaffected. Recorded in `gate/README.md` §0 next to the DNAT note; the real test is
  `docker version` (Server >= 28.0), since distro-packaged engines lag. (Docker port-publishing docs
  + Engine 28.0.0 release notes, 2026-09-05.)
- **An Access app's `allowed_idps` defaults to every IdP on the account, and `PUT` is a full
  replace** -- omitted fields reset to their defaults, and there is no `PATCH` for them. Both read
  from Cloudflare's OpenAPI schema + docs, 2026-09-02, not from a live account. **Date-sensitive:**
  Cloudflare made its own IdP the default for Zero Trust orgs created from ~2026-06 and stopped
  auto-adding one-time PIN, so what a consumer's account actually carries depends on its age --
  re-check before rewording `gate/README.md` §1a's IdP note.
- **The publish-scp connection/copy cost is by design -- #67 weighed three reductions and kept the
  proven shape.** The four connections a publish opens (staging setup, transfer, swap, cleanup) are
  enumerated in the scaffold itself (`publish-scp.ps1.example:69-71`; the calls are at `:197`/`:204`/
  `:210`/`:219`), which also already documents the real remedy for handshake cost -- a ControlMaster
  stanza (`:69-99`) -- with the caveat that the stock Windows client (`System32\OpenSSH`) *errors out*
  on it rather than reusing connections (`:90-99`), so a stock-Windows consumer pays every handshake.
  Against that baseline, `/code-review` proposed three reductions, all verified against the current
  tree and all declined: (1) **folding the cleanup ssh into the swap tail** (4->3 connections)
  sacrifices the deliberately-separated cleanup-failure warning (`:215-221`) unless a sentinel exit
  code is added to keep both; (2) **`cp -al` in the swap** (`:210`) hardlinks instead of re-writing,
  ~halving the copy time and the empty-live-dir window, but changes a twice-reviewed command for a
  gain #67 measured at single-digit-to-tens-of-ms (staging/live are guaranteed siblings, `:193-194`,
  so same-filesystem holds); (3) **tarring the build** (4->2 connections, and the trailing-dot nesting
  gotcha disappears) adds Windows-bsdtar mode-bit and PowerShell<7.4 binary-pipe caveats. Only
  `cp -al`'s **correctness** is provable from a dev session (a plain container per the docker-nucbox
  constraint); the perf figures and any end-to-end are real-box claims. The proven shape was kept per
  `CLAUDE.md`'s ground-truth rule; per-option detail lives in #67. (Verified against the current tree,
  2026-09-05.)

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
| `Rackbops/rackbops-ui-ux-std-lib` showcase | nginx-static | pull (git timer) | **Live** (`Rackbops/rackbops-ui-ux-std-lib#2`, shipped). Confirms the repo-root web-root knob for real (sibling `../styles` import) -- but its gate is `Tooling/docs/per-app-cloudflare-access-tunnel.md`'s **per-app token-sidecar tunnel** (zero published host port; `cloudflared` sidecar in its own compose project), not this repo's shared loopback-bound-port `gate/`. `Tooling`'s own doc calls that pattern out as the right one for a brand-new app-specific endpoint, so this is a deliberate divergence, not a template gap -- see [Open questions](#open-questions). |
| `Rackbops/artifact-console` | **node-app** | pull (`deploy-pull` timer, image-digest diff) | **Source of `node-app`.** The tier genericizes its **container contract** (image `ghcr.io/rackbops/artifact-console`, port 8787, three named volumes config/state/store) from artifact-console's shipped `deploy/`, plus its **#23 pull-deploy design** (the digest-diff `deploy-pull` swap) and **std-lib's token-sidecar** tunnel -- the pull/sidecar are not in that shipped `deploy/`, which still builds locally. Uses the token-sidecar, not the shared loopback-bound `gate/`. Going live on nucbox is pending (`artifact-console#23`'s apply). |
| `Rackbops/kenzen` | **node-app** | pull (`deploy-pull` timer, image-digest diff) | **Live on nucbox** (`Tooling#479`), and **source of `node-app/ci/`** -- `release.yml.example` and `image-ratchet.md` (`Tooling#511`) genericize Kenzen's own `.github/workflows/{release,image-ratchet}.yml`, the multi-arch-build-on-tag and build-real-image-and-assert shapes `artifact-console`'s own `deploy/` doesn't carry a CI-workflow analog for. Same token-sidecar tunnel as `artifact-console`'s row above. |

**The repo-root web-root knob is now run for real** -- by the `rackbops-ui-ux-std-lib` showcase
above (the sibling `../styles` import), so it is no longer inferred-only: the knob itself and both
`nginx.conf.*.example` deny blocks that make it safe (landed in #19) are confirmed by a running
deployment. That consumer's gate differs from this repo's shared `gate/`, so it does NOT prove the
*shared* gate end-to-end -- that caveat (top of this section) still stands; only the web-root knob
is what it confirms.

**`workers/file-issue/` has one consumer so far, and it doesn't fit the table above.** The table's
columns (`Base server` / gate-style `Publish`) describe the `gate/` + `servers/<name>/` model; a
Worker has neither a base server nor a loopback origin to publish onto, so it gets its own line
instead of a forced-fit row: `Rackbops/Tooling`'s `tools-site/worker/`, live on
`tools.rackbops.com`/`tools.owhee.com` (`Tooling#638`, given back as `Tooling#661`). **Source.**
Live on its own deployed Worker; `workers/file-issue/` is the genericized `.example` extraction from
it. `tools-site/README.md` records which of the two copies is canonical and which direction fixes
flow.

## Open questions

- **A second base server's shape** -- **partly resolved:** the dynamic-app case is now built as
  [`servers/node-app/`](servers/node-app/), extracted from `Rackbops/artifact-console` (a real
  consumer, not speculatively). Its publish/serve logic (an image-digest `deploy-pull` that swaps the
  container, a token-tunnel sidecar) is genuinely different from nginx-static's git/scp file publish,
  so nothing was lifted into a shared dir -- the per-server split holds. Still open for a *non-nginx
  static* server, if a real consumer ever needs one.
- **Where the shared gate lives once a dynamic-server variant exists** -- probe: with two real
  server tiers using the same gate, confirm the single shared `gate/` still serves both cleanly, or
  whether anything gate-side needs a per-server hook. No action until that second tier is real.
- **Should the per-app token-sidecar pattern become a second `gate/` variant here?**
  `rackbops-ui-ux-std-lib` (see Known consumers above) used it instead of this repo's shared
  loopback-bound-port gate, on `Tooling/docs/per-app-cloudflare-access-tunnel.md`'s explicit
  advice that it's the right shape for a brand-new app-specific endpoint (vs. this repo's gate,
  which is right for a stable, already-established shared tool). `rackbops-ui-ux-std-lib` uses it
  **live**; `artifact-console` **adopts** it via [`servers/node-app/`](servers/node-app/) but its
  nucbox apply is still **pending** (`artifact-console#23`) -- so today std-lib is the one live user,
  node-app the scaffolded second. Once #23 applies, extracting the token-sidecar as a documented
  second gate shape here is justified -- a follow-up. Until then, `node-app`'s README documents the
  token-tunnel divergence inline and defers the shared parts (Access app, DNS, closed-door verify) to
  `gate/README.md`.

## Declined proposals (considered, not adopted -- do not re-raise)

Changes a `/code-review` pass proposed against the scaffolds, each **weighed and declined** -- the
template keeps its proven shape rather than leading its reference consumers free-hand (the
ground-truth rule, top of file). Every one is CONFIRMED-mechanics-sound but a trade-off, not a fix,
and none is provable end-to-end from a dev session. **A review pass -- including a future
`/code-review` -- must not re-file these; `CLAUDE.md` carries the same instruction.** Revisit one only
if the reference consumer it diverges from adopts it on a real box first, at which point it is
re-genericized here. #81, #82, #83, #84 are closed *not planned*; #67 -- the publish-scp cost
proposals (fold the cleanup ssh / `cp -al` in the swap / tar the build) -- is closed *completed*, its
trade-off analysis recorded in the publish-scp cost bullet under **Confirmed facts** above.

- **Pull model (#83, #84) -- declined for the template.** Both are `/code-review` proposals that are technically sound but would make the
  scaffold LEAD its reference consumer's proven `deploy/` instead of tracking it, and neither is
  provable from a dev session -- so per the ground-truth rule (top of file) they wait for `rackbops`
  to adopt them on a real box first, then get re-genericized here. Recorded so the analysis isn't
  re-derived; the proven shapes stand meanwhile.
  - **#83 -- fold the git stall guard into `deploy-pull.sh`.** Replace today's transport-split,
    box-side README guard (`README.md:38`, the HTTPS `-c http.lowSpeed*` on the clone; `:84-86`, the
    SSH `Host` alias's `ConnectTimeout`/`ServerAlive*`) with one versioned pair wrapping the pull at
    `deploy-pull.sh.example:50`: `export GIT_SSH_COMMAND="ssh -o ConnectTimeout=15 -o
    ServerAliveInterval=15 -o ServerAliveCountMax=3"` + `git -c http.lowSpeedLimit=1000 -c
    http.lowSpeedTime=30 pull --ff-only --quiet`. Mechanics: each `-o`/`-c` is a no-op for the other
    transport, and
    `ssh -G` confirms (verified locally 2026-09-06) the `-o` timeouts merge in while a `Host` alias
    keeps its `IdentityFile`/`IdentitiesOnly`. Blocker: `GIT_SSH_COMMAND` overrides a consumer's own
    `core.sshCommand`/`GIT_SSH` -- an `ssh -i key` (non-alias) auth setup would lose its key -- it
    diverges from `rackbops`, and the initial hand-run clone's guard stays in the README regardless
    (the script only runs post-clone).
  - **#84 -- switch the timer to `OnCalendar=*:0/5` + `Persistent=true`** (from
    `OnBootSec=2min`+`OnUnitActiveSec=5min`, `deploy-pull.timer.example:25-26`), which would retire
    that timer's Persistent-omission rationale (`:27-33`) and the OnUnitActiveSec re-arm /
    systemd#21600 hedge at `deploy-pull.service.example:39-48`. Blocker:
    it replaces `rackbops`'s proven `OnUnitActiveSec=5min` (Sources, above); the boot catch-up it
    relies on is pure systemd-timer behavior a container here can't exercise (unverified on a real
    box); and the timer file already documents the switch as a consumer OPTION
    (`deploy-pull.timer.example:32`), so the default stays the proven monotonic form rather than
    changing under every consumer.
- **nginx serve/mount (#81, #82) -- declined for the template.**
  Like #83/#84 above, both are `/code-review` proposals with CONFIRMED mechanics that are design
  trade-offs rather than fixes -- each diverges from the reference consumers (#82 from a LIVE one), so
  their own verdicts route them to the consumers, not a free-hand template edit, and neither is proven
  end-to-end from a dev session. Recorded so the option isn't re-derived; the proven shapes stand
  meanwhile. The two also partially conflict (see #81's added deny rule vs #82 removing them), so they
  are alternatives, not a stack.
  - **#81 -- directory-mount `conf.d` so `nginx -s reload` works after a pull.** Today's single-file
    bind at `compose.yaml.example:68-73` (`./nginx.conf` -> `/etc/nginx/conf.d/default.conf`) pins the
    old inode when a `git checkout` swaps it -- the sole reason the template rules out `reload` after
    a pull (the caveat family at `nginx.conf.*.example:17-21`, `README.md:258-261`,
    `deploy-pull.sh.example:162`). A directory mount (`./nginx` -> `/etc/nginx/conf.d`) resolves by
    path each open, so `docker exec <app> nginx -s reload` reads the pulled file -- and `reload` is
    validate-first, avoiding the `restart` -> `[emerg]` -> `restart: unless-stopped` crash-loop the
    issue flags. Its `create_host_path: false` dependency already landed (#91). Cost: adds a
    `location ^~ /nginx/ { return 404; }` for the repo-root knob (which #82 would then remove). Blocker:
    diverges from BOTH reference consumers; the end-to-end reload needs a real box (spans compose +
    both nginx headers + README + deploy-pull.sh).
  - **#82 -- two sibling mounts as an allowlist for the repo-root knob.** Replace the repo-root mount
    (`.`) + the deny blocklist (`nginx.conf.*.example:57-81`) with `./site` + `./styles` siblings and
    `location /styles/ { root /usr/share/nginx; }` -- RFC 3986 clamps a page's `../styles` at root and
    the `root` trick maps it, so only `site/`+`styles/` are ever served (an allowlist by
    construction). That would retire the deny rules, the "`/` needs a root `index.html`/302" caveat,
    the SPA 500-loop caveat, and the push-model exclusion. Blocker: the deny blocks it removes are the
    public-repo safety mechanism hiding `.git/`, `compose.yaml`, `deploy/`, and the root `.ps1` that
    carries `<user>@<host>` -- a security-relevant redesign, on the repo-root shape a LIVE consumer
    already runs (`rackbops-ui-ux-std-lib` showcase, Known consumers above). Filing so the option is
    recorded; adopt only if the consumers move to it.

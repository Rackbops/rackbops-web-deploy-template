# rackbops-gated-deploy-template -- Claude Instructions

A public, copyable **template repo** (shared tier, like `roshne/addon-ci`) for deploying a web
thing behind a **Cloudflare-Access-gated loopback origin**. It ships `.example` scaffold files +
runbooks, **not** a running app or a library anything imports. It is **not** an app framework and
**not** the app-shell/feature-hooks template (that's a separate, future repo). See `README.md`.

The repo is an **extensible monorepo**: one shared, origin-agnostic **`gate/`** (the Cloudflare +
loopback + verify runbook, identical for any origin) plus a **`servers/<name>/`** tier of pluggable
base servers. Today only `servers/nginx-static/` exists; the tier is left open for future base
servers (another static-file server, or a dynamic app server) **but they are scaffolded only when a
real consumer needs one** -- never pre-built empty. This altitude guard is the whole reason the
repo is shaped this way; don't add a speculative `servers/<x>/` with no consumer.

My personal `~/.claude/CLAUDE.md` governs *how I work* -- the review gate, escalation, git &
shipping, commit mechanics, search-tool routing, and shell choice. It is **not restated here**;
this file covers only what's specific to this repo.

**Commit convention:** Conventional Commits `type(scope): subject` -- `feat`/`docs`/`chore`, scopes
like the file or layer touched (`gate`, `nginx-static`, `compose`, `publish`). Match the log once it
exists.

## Ground truth: this repo is DERIVED, cite the sources it was extracted from

The `.example` files and runbooks are not authored from first principles -- each is genericized
from a **real, running** implementation, and that provenance is the ground truth. When changing
one, check it against its source rather than inventing behavior:

- `servers/nginx-static/` (`compose.yaml.example`, `nginx.conf.example`,
  `publish/publish-scp.ps1.example`) -- extracted from `roshne/Tooling`'s `tools-site/` (the `#281`
  deploy artifact; the scp script's stage-then-swap design and its `$LASTEXITCODE`/empty-build
  guards were proven and adversarially reviewed there).
- `servers/nginx-static/publish/deploy-pull.sh.example` + `.service`/`.timer` -- extracted from
  `roshne/rackbops`'s `deploy/` (its live git-pull-on-a-systemd-timer auto-deploy).
- `gate/README.md` -- generalized from the Cloudflare Tunnel + Access rollouts in `roshne/Tooling`'s
  `docs/*-remote-access.md` (private), proven identical across origins in `Tooling#282`.

Mark any claim you can't trace to one of those **inferred** or **unknown**, per personal's Claims
discipline. A false factual claim in a runbook (`gate/README.md`, a server README, the root
`README.md`) is a MAJOR finding, not "docs polish."

## Public repo: no real infrastructure identifiers, ever

This repo is **public**. Nothing real about anyone's infrastructure belongs in it -- no hostnames,
LAN IPs, Cloudflare account emails, zone IDs, tunnel UUIDs, Zero Trust team names, AUD tags, or
service tokens. Everything is `<PLACEHOLDER>`. A concrete value from a real box or account leaking
into a `.example` or a runbook is an escalation-worthy mistake (personal's Escalation: a live data
path / shipped identifier), not a normal edit. When genericizing from the private sources above,
scrub every real value.

## Irreversible: the repo NAME is a shipped identifier

Consumers reference this repo by name (`roshne/rackbops-gated-deploy-template`) in their own docs
and in `Tooling`'s scaffold pointer. Renaming it breaks those references invisibly -- treat a
rename as an escalation (create-new + redirect, per personal), not a casual change.

## Testing & checks

**No CI on this repo** -- by design (matches `addon-ci`). The `.example` files are copied and
adapted per consumer, who owns testing their own copy. Before committing a change here, apply the
same floor by hand that a consumer's CI would:

- **PowerShell** -- parse-check `servers/nginx-static/publish/publish-scp.ps1.example` with
  `[System.Management.Automation.Language.Parser]::ParseFile(...)` (the exact check `Tooling`'s
  `powershell-app.yml` runs). It's a `.example`, so a consumer renames it to `.ps1` -- the parser
  reads content, not extension, so a temp copy or direct parse works.
- **Shell** -- `bash -n servers/nginx-static/publish/deploy-pull.sh.example` (and `shellcheck` if
  available).
- **Docs** -- a claim in any runbook (`gate/README.md`, a server README, root `README.md`) or this
  file must be traceable to a real source file (see Ground truth). Verify while writing; one
  claims-vs-code pass before calling it done.

**A green local parse is not proof the deploy works** -- only a real consumer standing up a real
box + Cloudflare gate proves the end-to-end (the reference `tools-site`/`rackbops` deployments are
that proof for the extracted shape). Say what you verified vs. what still needs a real rollout, per
personal's **Done means**.

## Code style

Follows personal's **Code style** baseline. This repo's individuality:

- **Files are `.example`** -- they're read as templates, so favor inline explanatory comments over
  terseness; a consumer reading the file is the audience. Keep console-printed strings ASCII (the
  PowerShell scaffold prints to a Windows cp1252 console) -- same rule as the source.
- **Scaffolds carry `<PLACEHOLDER>` markers**, not plausible-looking fake values, so a
  copy-paste-without-editing fails loudly rather than silently pointing at the wrong box.

## Key gotchas

- **`.gitattributes` pins LF** (`* text=auto eol=lf`, `.ps1` forced LF) -- so the PowerShell
  scaffold's line endings don't flip per clone.
- **The scp scaffold's stage-then-swap and trailing-dot source are load-bearing, not decoration** --
  they're the fixes that made the reference `tools-site` publish safe (interrupted-transfer safety;
  avoiding a nested `dist/dist/`). Don't "simplify" them back to a direct `scp` into the live dir.

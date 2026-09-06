# rackbops-web-deploy-template -- Claude Instructions

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

**Commit convention:** Conventional Commits `type(scope): subject` -- e.g.
`feat`/`fix`/`docs`/`chore`/`ci` (all in the log), scopes like the file or layer touched (`gate`,
`nginx-static`, `compose`, `publish`). Match the log.

## Ground truth: this repo is DERIVED, cite the sources it was extracted from

The `.example` files and runbooks are not authored from first principles -- each is genericized
from a **real, running** implementation, and that provenance is the ground truth. When changing
one, check it against its source rather than inventing behavior. The source of each scaffold, and
what has been proven about it, is the ledger's job, not this file's: it lives in
[`CONTEXT.md`](CONTEXT.md)'s "Sources" and "Confirmed facts" sections -- read (and update) it there,
so a provenance correction lands in one place.

Mark any claim you can't trace to a `CONTEXT.md` source **inferred** or **unknown**, per personal's
Claims discipline. A false factual claim in a runbook (`gate/README.md`, a server README, the root
`README.md`) is a MAJOR finding, not "docs polish."

## Declined proposals -- do not re-raise in review

A `/code-review` pass reads this file and `CONTEXT.md` as context. The proposals below were weighed
and **declined** (their issues closed -- #81/#82/#83/#84 as *not planned*, #67 as *completed* with
its trade-off analysis recorded): the template keeps its proven shape per the Ground-truth rule
above. **Do not re-file them.** Each one's rationale, mechanics, and the blocker
are in `CONTEXT.md`'s "Declined proposals" section; revisit one only if the reference consumer it
diverges from adopts it on a real box first.

- #67 -- publish-scp connection/copy cost (fold the cleanup ssh / `cp -al` in the swap / tar the build)
- #83 -- fold the git stall guard into `deploy-pull.sh` (`GIT_SSH_COMMAND` + `git -c http.*`)
- #84 -- switch the deploy-pull timer to `OnCalendar=*:0/5` + `Persistent=true`
- #81 -- directory-mount `conf.d` so `nginx -s reload` works after a pull
- #82 -- two sibling mounts (allowlist) for the repo-root web-root knob, dropping the deny rules

No formal finding-suppression file exists for the local `/code-review` -- this context is the
mechanism. A repo-root `REVIEW.md` "Do not report" section would additionally cover the managed
GitHub Code Review service, if that is ever enabled on this repo.

## Public repo: no real infrastructure identifiers, ever

This repo is **public**. Nothing real about anyone's infrastructure belongs in it -- no hostnames,
LAN IPs, Cloudflare account emails, zone IDs, tunnel UUIDs, Zero Trust team names, AUD tags, or
service tokens. Everything is `<PLACEHOLDER>`. A concrete value from a real box or account leaking
into a `.example` or a runbook is an escalation-worthy mistake (personal's Escalation: a live data
path / shipped identifier), not a normal edit. When genericizing from the private sources above,
scrub every real value.

## Irreversible: the repo NAME is a shipped identifier

Consumers reference this repo by name (`Rackbops/rackbops-web-deploy-template` -- the canonical
slug) in their own docs and in `Tooling`'s scaffold pointer. Renaming it breaks those references
invisibly -- treat a rename as an escalation (create-new + redirect, per personal), not a casual
change. (It was renamed once, gated- -> web-, right after creation while nothing yet consumed it --
the safe window; GitHub's redirect covers the old URL regardless.)

The repo also **moved owner**, roshne -> the `Rackbops` org, so `roshne/rackbops-web-deploy-template`
still resolves but only by GitHub's owner redirect -- which dies the moment anything is created at
that name. Write `Rackbops/...` in anything new. `Tooling`'s scaffold pointer still carries the old
spelling (`Rackbops/Tooling#349` tracks that sweep).

## Overriding personal's "config never lives in the repo"

Personal's **Application config & deployment** says an app must never depend on its repo directory
existing, and that a repo overriding one of my rules must say so and say why. **The pull model
overrides it, deliberately.** There the clone IS the Dockge stack dir at `/opt/stacks/<app>/` --
already the machine location personal prescribes for a service, so the only real deviation is that
this location is also a checkout: `nginx.conf` is bind-mounted straight out of it and
`compose.yaml` is read from it in place. That is sound here and not a precedent for an app: these
are content-free config fragments with no secrets and no state, the operator opts into the model
knowingly, and it is what the reference consumer actually does. (The one real secret, the read-only
deploy key, lives in `~/.ssh`, not the clone.) The push model has no such dependency. Anything
carrying secrets or persistent state still follows personal's rule.

## Testing & checks

**No lint/test CI on this repo** -- by design (matches `addon-ci`). The `.example` files are copied
and adapted per consumer, who owns testing their own copy. The one workflow present,
`.github/workflows/push-notify.yml`, is the maintainer's Discord push notifier -- repo plumbing, not
template content, and not a check. Before committing a change here, apply the same floor by hand
that a consumer's CI would:

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

- **`.gitattributes` pins LF** -- `* text=auto eol=lf` covers the repo, and `*.example text eol=lf`
  pins the scaffolds specifically, so their line endings don't flip per clone even if the wildcard
  is ever narrowed. Every scaffold ends in `.example` -- `publish-scp.ps1.example` included -- so
  the `*.ps1` line matches nothing today and is forward cover only; don't credit it for the
  scaffold.
- **The scp scaffold's stage-then-swap and trailing-dot source are load-bearing, not decoration** --
  they're the fixes that made the reference `tools-site` publish safe (interrupted-transfer safety;
  avoiding a nested `dist/dist/`). Don't "simplify" them back to a direct `scp` into the live dir.

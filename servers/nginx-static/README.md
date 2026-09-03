# nginx-static base server

The **nginx-static** base server: a stock `nginx:alpine` container serving files off a read-only
bind mount, bound to loopback. This is the only base server implemented today; the repo's
[`servers/`](../) tier leaves room for sibling base servers (another static-file server like a Node
`serve`/`http-server` or Caddy; or a dynamic app server) as `../<name>/` later — all behind the
same shared [`gate/`](../../gate/).

## Files

| File | What it is |
|---|---|
| [`compose.yaml.example`](compose.yaml.example) | The Dockge stack: `nginx:alpine`, loopback bind, the web-root + port knobs. |
| [`nginx.conf.example`](nginx.conf.example) | The `server {}` fragment: `/healthz` + a pick-one SPA-vs-static `location /`. |
| [`publish/publish-scp.ps1.example`](publish/publish-scp.ps1.example) | **Push** publish: build locally, scp to the box via a stage-then-swap. |
| [`publish/deploy-pull.sh.example`](publish/deploy-pull.sh.example) + [`.service`](publish/deploy-pull.service.example) / [`.timer`](publish/deploy-pull.timer.example) | **Pull** publish: the box clones the repo and `git pull`s on a systemd-timer poll. |

## Bring it up on the box

How the stack dir gets populated differs by model (see "Push or pull?" below for which applies to
you) — pick the matching block. In the push model, `compose.yaml` + `nginx.conf` are shipped once
at setup and only the web-root content is reshipped per update. In the pull model everything
arrives with the clone, and a later pull ships whatever you committed — content, `nginx.conf`,
`compose.yaml`, or the `deploy/` units — see "Updating" below for what each of those requires.

### Pull model: clone as `<user>`, not root

First commit + push the adapted `compose.yaml`, `nginx.conf`, and `deploy/` files to the app repo —
the box only ever gets what's on the branch it clones. Then:

```bash
# on the box, logged in as <user> -- the account the service's User= line names
sudo mkdir -p /opt/stacks/<app>
sudo chown <user>:<user> /opt/stacks/<app>
git clone <REPO_URL> /opt/stacks/<app>       # as <user>, into the still-EMPTY dir
# (private repo? do the deploy-key setup below FIRST, then clone through its alias instead)
```

`compose.yaml`, `nginx.conf`, and `deploy/` all arrive with the clone — there's nothing to copy in
separately, and nothing may be copied in *before* it: `git clone` refuses a non-empty destination
(`destination path already exists and is not an empty directory`). Cloning AS `<user>` matters: the
timer's `User=<user>` service runs `git pull` as `<user>`, and a clone owned by a different user
trips git's `dubious ownership` check on every run (cloning as root then `chown`-ing after also
works, but only with `chown -R`, which is easy to forget and leaves no obvious symptom until the
timer starts failing). If you're logged in as some other account, run the clone as `<user>` with
`sudo -u <user> -H git clone ...` (`-H` sets `HOME` to `<user>`'s, matching the service's
`Environment=HOME=` line).

For a **private repo**, give `<user>` a read-only deploy key *before* cloning, so this clone and
every later `git pull` authenticate non-interactively:

```bash
# on the box, as <user> -- a key just for this repo, plus a host alias that scopes it to this repo
ssh-keygen -t ed25519 -f ~/.ssh/<app>_deploy -N "" -C "<app> deploy key"
cat ~/.ssh/<app>_deploy.pub    # add at github.com/<OWNER>/<REPO> -> Settings -> Deploy keys,
                               # with "Allow write access" UNCHECKED (pull-only)
cat >> ~/.ssh/config <<'EOF'

Host github-<app>
  HostName github.com
  User git
  IdentityFile ~/.ssh/<app>_deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
# then the mkdir + chown lines above, and clone through the alias in place of <REPO_URL>:
git clone git@github-<app>:<OWNER>/<REPO>.git /opt/stacks/<app>
```

Never commit on the box: once `main` moves past a commit made here, the timer's `git pull
--ff-only` refuses (loudly, in the journal) rather than merging — the box is a pure consumer.

### Push model: mkdir, then scp

```bash
# on the box
sudo mkdir -p /opt/stacks/<app>
sudo chown <user>:<user> /opt/stacks/<app>   # so publish-scp.ps1 can write here as <user>, not root
# copy compose.yaml and nginx.conf into /opt/stacks/<app>/ by hand (scp them from your machine)
```

Then run `publish-scp.ps1` once from your machine to ship the initial build. The script creates the
web-root dir under the stack dir itself (its swap step does `mkdir -p`), so there's nothing to
pre-create.

### Both models, once the stack dir is populated

```bash
cd /opt/stacks/<app> && sudo docker compose up -d
# if you kept the /healthz block in nginx.conf:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<HOST_PORT>/healthz   # 200
```

That's this server's half done. Now go to [`../../gate/README.md`](../../gate/README.md): its
step 0 verifies the loopback bind — that bind is the gate's security floor, so the check lives
there rather than in each server README — and the rest of it puts the Access gate in front.

## Push or pull?

The one real fork in how new content reaches the box. Both end with nginx serving files off the
read-only mount; they differ only in transport:

- **Push (`publish-scp.ps1`)** — build on your machine, scp the output to the box. Use when the box
  **cannot or should not hold a clone** of the repo: a private repo you can't or won't give the box
  a read-only deploy key for, or a box with no repo access.
  The stage-then-swap design means an interrupted transfer never half-empties the live site.
- **Pull (`deploy-pull.sh` + timer)** — the box holds the repo clone AS its stack dir and `git
  pull`s on a poll. Use when the repo can live on the box directly. Simpler, but the repo has to be
  reachable/clonable from the box.

Delete whichever pair you don't use.

### Installing the pull timer (box side, one time)

The `.service`/`.timer` are **system** units (they run as a system unit that drops to `<user>` via
`User=`/`HOME=` — that drop-to-user form is why they're system units, not `--user` ones). In your
app repo, copy `deploy-pull.service.example` to `deploy/<app>-deploy.service` and
`deploy-pull.timer.example` to `deploy/<app>-deploy.timer` — both change stem AND drop `.example`,
whereas `deploy-pull.sh.example` becomes `deploy/deploy-pull.sh`, keeping its stem (the `.service`'s
`ExecStart=` names that script path and the `.timer`'s `Unit=` names the service's unit name, so
keep all three in sync). They arrive with the clone in the pull model, since they live under
`deploy/` in the repo. Install them with `sudo`:

```bash
# on the box, in /opt/stacks/<app>/deploy/ (already there via the clone -- see "Bring it up" above)
sudo cp /opt/stacks/<app>/deploy/<app>-deploy.service /etc/systemd/system/
sudo cp /opt/stacks/<app>/deploy/<app>-deploy.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now <app>-deploy.timer
# verify:
sudo systemctl start <app>-deploy.service                 # force one run
journalctl -u <app>-deploy.service -n 20 --no-pager       # "up to date" or "updated <a> -> <b>"
systemctl list-timers <app>-deploy.timer --no-pager       # next scheduled run
```

Re-copy + `sudo systemctl daemon-reload` after editing a unit. Disable with `sudo systemctl
disable --now <app>-deploy.timer`. (Prefer cron? One line polls without the systemd machinery --
but it must go in `<user>`'s OWN crontab, run as `<user>` via `crontab -e` (not `sudo crontab -e`,
which edits root's crontab and hits the same dubious-ownership trap the clone step above avoids, or
on an older git succeeds as root and leaves root-owned `.git` files that lock `<user>` back out):
`*/5 * * * * /bin/bash /opt/stacks/<app>/deploy/deploy-pull.sh`. Its output goes to cron's mail,
not the journal, so the `journalctl` verify line above doesn't apply -- redirect it to a log file
if you want to see it.)

## Web-root knob

`compose.yaml`'s content mount is not always a `dist`/`site` subdir — it's whichever local dir
should become nginx's web root. Three choices:

- a build artifact dir (`./dist`, `./build`)
- a hand-authored dir (`./site`)
- the **repo root itself** (`.`) — mount it when `index.html` imports a sibling of its own
  directory (e.g. a `site/index.html` that does `import "../styles/all.css"` — serving only
  `site/` would 404 that import) and putting the whole tree under the web root is the only way to
  reach both.

Pick the mount that puts every asset the page references under the web root.

**The repo-root mount is pull-model only** — the push model's `publish-scp.ps1` refuses to target
it (`$LocalDirName` can't be `.`); only a pull-model box's clone doubles as both the stack dir and
the web root. **It's also currently inferred, not extracted from a running deployment** — no
consumer in [`CONTEXT.md`](../../CONTEXT.md)'s "Known consumers" table runs it yet, per this repo's
ground-truth rule.
Two consequences to know before using it:

- It serves EVERYTHING in the clone unless `nginx.conf` denies it — `.git/`, `compose.yaml`,
  `nginx.conf`, `deploy/*.service`, all of it. `nginx.conf.example` denies these by default
  (dotfiles, `compose.yaml`, `nginx.conf`, `deploy/`) — don't remove those blocks if you use this
  mount.
- `/` needs something to actually resolve to: `try_files` finds nothing for a bare `/` unless a
  root `index.html` exists (a `site/index.html` is not `/index.html`). Either add a root
  `index.html` (e.g. one that redirects into your real entry point), or add
  `location = / { return 302 /site/; }` (adjust the path) — otherwise a gated visitor hits nginx's
  bare 403 at `/` with no indication where the real site lives. With the SPA fallback variant (A)
  of `nginx.conf.example` active, a missing root `index.html` is worse than a 403 at `/` alone: ANY
  unmatched path also 500s (nginx's `try_files ... /index.html` fallback tries to internally
  redirect to the still-missing `/index.html` and loops until nginx aborts the request) — one more
  reason to add the root `index.html`/redirect above rather than leave it unresolved.

## Updating

- **Content** — via your chosen publish mechanism above. Served live off the read-only mount;
  **no restart needed** (nginx re-reads files per request; hashed asset filenames mean a fresh
  `index.html` always references the assets that shipped with it).
- **`nginx.conf`** — always needs `docker compose restart <app>` to take effect; this is the ONE
  change that needs a restart. How it reaches the box differs by model: the scp push never
  re-ships it (re-copy it to the stack dir by hand, then restart); the git-pull model ships
  whatever you commit, and `deploy-pull.sh`'s diff check flags a `nginx.conf` change with the
  restart reminder in its log. Either way, do NOT rely on `nginx -s reload` after a pull -- `git
  checkout` replaces the file via a new inode, and Docker's single-file bind mount keeps watching
  the old one, so a reload silently keeps serving the stale config. `reload` is fine after an
  in-place scp/cp, which overwrites the file rather than replacing it.
- **`compose.yaml` or a `deploy/*.service`/`*.timer` unit** — pull model only (the push model never
  ships either): `deploy-pull.sh`'s diff check flags a `compose.yaml` change with a reminder to run
  `docker compose up -d`, and a unit-file change with a reminder to re-copy it to
  `/etc/systemd/system/` and run `sudo systemctl daemon-reload` -- see its log, same as the
  `nginx.conf` case above.

## SPA vs. plain static

`nginx.conf.example` ships both `location /` bodies — pick one:

- **SPA fallback** (`try_files $uri $uri/ /index.html;`) for a client-routed build (React/Vite,
  like `tools-site`) so deep links resolve to the app.
- **Plain static** (`try_files $uri $uri/ =404;` + an optional `error_page 404`) for hand-authored
  HTML (like the `rackbops` one-pager) so unknown paths 404 honestly.

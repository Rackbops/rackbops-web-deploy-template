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
you) — pick the matching block. Either way, `compose.yaml` + `nginx.conf` end up in place once, and
only the web-root content gets reshipped per update — for the pull model, `nginx.conf` and
`deploy/` can also change on a later pull; see "Updating" below for what that requires.

### Pull model: clone as `<user>`, not root

```bash
# on the box
sudo mkdir -p /opt/stacks/<app>
sudo chown <user>:<user> /opt/stacks/<app>
sudo -u <user> git clone <your-repo-url> /opt/stacks/<app>
```

`compose.yaml`, `nginx.conf`, and `deploy/` all arrive with the clone — there's nothing to copy in
separately. Cloning AS `<user>` matters: the timer's `User=<user>` service runs `git pull` as
`<user>`, and a clone owned by a different user trips git's `dubious ownership` check on every run
(cloning as root then `chown`-ing after also works, but only with `chown -R`, which is easy to
forget and leaves no obvious symptom until the timer starts failing). For a private repo, set up a
read-only deploy key (or an SSH config `Host` alias) for `<user>` *before* cloning, so this clone
and every later `git pull` can authenticate non-interactively. Never commit on the box — the
timer's `git pull --ff-only` assumes a clean working tree.

### Push model: mkdir, then scp

```bash
# on the box
sudo mkdir -p /opt/stacks/<app>
sudo chown <user>:<user> /opt/stacks/<app>   # so publish-scp.ps1 can write here as <user>, not root
# copy compose.yaml and nginx.conf into /opt/stacks/<app>/ by hand (scp, or paste via Dockge)
```

Then run `publish-scp.ps1` once to ship the initial build into the (now-existing) web-root dir.

### Both models, once the stack dir is populated

```bash
cd /opt/stacks/<app> && sudo docker compose up -d
# verify it serves on loopback only:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<HOST_PORT>/          # 200
ss -ltnp | grep <HOST_PORT>                                                     # bound 127.0.0.1, NOT 0.0.0.0
# if you kept the /healthz block in nginx.conf:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:<HOST_PORT>/healthz   # 200
```

Then put the Cloudflare Access gate in front of it: [`../../gate/README.md`](../../gate/README.md).

## Push or pull?

The one real fork in how new content reaches the box. Both end with nginx serving files off the
read-only mount; they differ only in transport:

- **Push (`publish-scp.ps1`)** — build on your machine, scp the output to the box. Use when the box
  **cannot or should not hold a clone** of the repo: a private repo, or a box with no repo access.
  The stage-then-swap design means an interrupted transfer never half-empties the live site.
- **Pull (`deploy-pull.sh` + timer)** — the box holds the repo clone AS its stack dir and `git
  pull`s on a poll. Use when the repo can live on the box directly. Simpler, but the repo has to be
  reachable/clonable from the box.

Delete whichever pair you don't use.

### Installing the pull timer (box side, one time)

The `.service`/`.timer` are **system** units (they run as a system unit that drops to `<user>` via
`User=`/`HOME=` — that drop-to-user form is why they're system units, not `--user` ones). In your
app repo, rename `deploy-pull.service.example` → `deploy/<app>-deploy.service` and
`deploy-pull.timer.example` → `deploy/<app>-deploy.timer` (same rename `deploy-pull.sh.example`
itself gets, dropping `.example`) — these arrive with the clone in the pull model, since they live
under `deploy/` in the repo. Install them with `sudo`:

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
`*/5 * * * * /bin/bash /opt/stacks/<app>/deploy/deploy-pull.sh`.)

## Web-root knob

`compose.yaml`'s content mount is not always a `dist`/`site` subdir — it's whichever local dir
should become nginx's web root, and that includes the **repo root itself** when `index.html`
imports a sibling of its own directory (e.g. a `site/index.html` that does `import
"../styles/all.css"` — serving only `site/` would 404 that import). Pick the mount that puts every
asset the page references under the web root.

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
  HTML (like `rackbops.com`) so unknown paths 404 honestly.

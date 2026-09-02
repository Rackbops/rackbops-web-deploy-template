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

The stack dir holds `compose.yaml` + `nginx.conf` (shipped **once** at setup) and the web-root
content (reshipped per update — see Publish below).

```bash
# on the box
sudo mkdir -p /opt/stacks/<app>
sudo chown <user>:<user> /opt/stacks/<app>   # so a push (scp) publish can write here as <user>, not root
# copy compose.yaml and nginx.conf into /opt/stacks/<app>/
```

Get the content there once (a first push, or the first `git pull` for the pull model — see below),
then:

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
`User=`/`HOME=` — that drop-to-user form is why they're system units, not `--user` ones). Install
them with `sudo`:

```bash
# on the box, after copying deploy-pull.sh + the units into /opt/stacks/<app>/deploy/
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
disable --now <app>-deploy.timer`. (Prefer cron? One line polls without the systemd machinery:
`*/5 * * * * /bin/bash /opt/stacks/<app>/deploy/deploy-pull.sh`.)

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
consumer in this repo's "Known consumers" table runs it yet, per this repo's ground-truth rule.
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

## SPA vs. plain static

`nginx.conf.example` ships both `location /` bodies — pick one:

- **SPA fallback** (`try_files $uri $uri/ /index.html;`) for a client-routed build (React/Vite,
  like `tools-site`) so deep links resolve to the app.
- **Plain static** (`try_files $uri $uri/ =404;` + an optional `error_page 404`) for hand-authored
  HTML (like `rackbops.com`) so unknown paths 404 honestly.

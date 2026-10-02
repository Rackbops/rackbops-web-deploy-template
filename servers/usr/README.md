# usr -- a `node-app`-shaped project (users, roles, SSO)

[usr](#what-usr-is-and-what-this-project-assumes) is a Hono API + React SPA over its own Postgres:
centralized users, app-scoped roles, and a cross-app SSO cookie that sibling apps verify offline against
its JWKS. This directory runs it the way [`../node-app/`](../node-app/README.md) runs any container app --
a built image, a per-app `cloudflared` token-tunnel sidecar, **no host port**, a deploy timer -- plus the
two things node-app does not cover: **a Postgres beside the app**, and **an Access bypass scoped to exactly
one path** (the JWKS). **Read node-app's README first**; this one only says what differs, and reuses
node-app's `publish/` scripts unchanged rather than copying them (a copy would drift from the #108 fix
and from the tunnel-token helper's hardening).

It is not a new base server: the shape is node-app's, and usr is the consumer. It is filed under
`servers/` beside the base servers it builds on.

**Placeholders** (this repo is public, so none of these is a real value): `<USR_HOSTNAME>` (usr's own public
hostname), `<COOKIE_DOMAIN>` (a parent domain of it and of the apps that sign in through it), `<TEAM>` and
`<USR_AUD>` (your Access team name and the usr Access app's AUD tag), `<TUNNEL_ID>`, `<BOX>` (the host that
runs this stack), `<BACKUP_HOST>` (a different host), `<STAGING_DIR>` (where the nightly dump is written on
`<BOX>`), `<CONSUMER_CONTAINER>`. The rest (`<USER>`, `<DATE>`, `<CLOUDFLARED_TAG>`, ...) are filled in
where they appear.

## What usr is, and what this project assumes

Read from usr's own repository (private, a different organisation's) at commit `bffa881`; the full SHA is in
[`CONTEXT.md`](../../CONTEXT.md#sources-what-each-scaffold-was-extracted-from). This repo is public, so those facts
are stated here **without** that repository's file paths, line numbers or internal route names (apart from the two
HTTP paths the runbook itself probes). Re-check any of them against that commit before relying on it.

- **The image.** A private ghcr package, published for `linux/amd64` only. Its CI pushes `latest` and
  `sha-<short>` on every push to `main`, and `X.Y.Z` / `X.Y` -- **without** a `v` -- on a version tag. It runs
  Node 24 on Alpine, listens on port 8432, ships no `HEALTHCHECK`, and runs as root (it has no `USER`).
- **The database.** It needs Postgres 18 and applies its own migrations at boot, before it listens. Its default
  connection string, set through `DATABASE_URL`, is `postgres://usr:usr@postgres:5432/usr`. Postgres 18 keeps
  its data in a version subdirectory, so the data directory is mounted at its **parent**, `/var/lib/postgresql`.
  usr's own compose also publishes loopback ports for local development, which this stack does not.
- **Health.** `GET /api/health` answers `{"ok":true}` with no authentication.
- **The JWKS.** `GET /.well-known/jwks.json` needs no authentication, is cacheable for five minutes, and serves
  **one** ES256 key. The key is generated the first time it is used and stored in the database (as two settings
  rows), so the database also holds the signing key.
- **SSO.** Off unless `USR_SSO_COOKIE_DOMAIN` is set. When set, every login also sets a short-lived signed
  identity cookie (`HttpOnly`, `Secure`, `SameSite=Lax`) on that parent domain, which sibling apps verify against
  the JWKS; its lifetime is `USR_SSO_TOKEN_TTL` (default 30 minutes).
- **First run and open mode.** While no local credentials, no OAuth provider and no API key are configured, usr
  is in *open mode*: every request is a root identity. A welcome screen (shown when there are also no users)
  creates the initial admin, who holds the seeded `usr:admin` role, and the break-glass local credentials.
  Configuring those is what ends open mode; merely creating users does not.
- **Roles.** Apps are string namespaces with no registration: a role is an app name plus a role name, and
  creating one needs admin rights, which `usr:admin` has. Names are lowercase letters, digits, `.`, `_` and `-`,
  starting with a letter or digit, at most 64 characters, so `ac`, `admin` and `viewer` are valid. Creating a
  role that already exists is refused. Assigning roles to a user **replaces** that user's whole role set.
- **The UI.** A Roles page creates a role from an app, a name and an optional description. A user's page assigns
  roles, grouped by app. The welcome screen asks for an email, a username and a password; a name is optional.

## Files

| File | Goes to | What |
|---|---|---|
| `compose.yaml.example` | `/opt/stacks/usr/compose.yaml` | `usr` + `postgres:18` + the `cloudflared` sidecar (behind the `tunnel` profile); no host port; healthchecks on `GET /api/health` and `pg_isready`; Postgres data in a host directory |
| `.env.example` | `/opt/stacks/usr/.env` (`chmod 600`) | the image, the registry login, the tunnel token, the Postgres password, usr's SSO and public-URL settings; **fill in, never commit** |
| *(node-app's)* `../node-app/publish/deploy-pull.{sh,service,timer}.example` | `/opt/stacks/usr/deploy/deploy-pull.sh`, `/etc/systemd/system/usr-deploy.{service,timer}` | the image auto-swap -- used as is, with `<app>` = `usr` and `SERVICE="usr"` |
| *(node-app's)* `../node-app/publish/set-tunnel-token.sh.example` | `/opt/stacks/usr/deploy/set-tunnel-token.sh` | writes the tunnel token into `.env` without it touching shell history |

The variable names for the image, the registry login and the tunnel token are node-app's own
(`IMAGE`, `IMAGE_TAG`, `REGISTRY`, `REGISTRY_USER`, `REGISTRY_TOKEN`, `CLOUDFLARE_TUNNEL_TOKEN`) because
those scripts read exactly those names; a differently named variable would make the script skip its login
and fail the pull on a private image.

## Runbook

Run it in this order. **Nothing here is done for you**: the Cloudflare steps are dashboard/API calls you
make, and the box steps run on `<BOX>`. Access comes first, so the hostname is never reachable without a
policy in front of it (the same rule as [`gate/README.md`](../../gate/README.md) step 1).

### 1. Access: the application, and the one bypass

**1a. The application.** Create the self-hosted Access app for `<USR_HOSTNAME>` exactly as
[`gate/README.md` step 1a](../../gate/README.md#1a-access-application) says (reuse your existing allow
policy by `id`, and read its note on pinning the login method). Capture its **AUD tag** as `<USR_AUD>`.

**1b. The JWKS bypass.** Consumers on other hosts fetch `https://<USR_HOSTNAME>/.well-known/jwks.json`
without an Access session -- the JWKS is public data by design (usr serves it unauthenticated, per the table
above) and a consumer's verifier cannot log in. So create a **second** self-hosted Access application whose
only destination is the single path `<USR_HOSTNAME>/.well-known/jwks.json`, with one policy: action
**Bypass**, include **Everyone**. Cloudflare documents that when rules overlap on a root path "the more
specific rule takes precedence" ([Access application paths](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/),
read 2026-10-02), so this path is bypassed and everything else on the hostname stays behind app 1a. (That
page's own example is `/eng` against `/eng/exec`; a hostname-wide app against a path app is the same rule
applied, which is **inferred** -- step 6's probes are what prove it.)

**The bypass is exactly `/.well-known/jwks.json`, nothing wider.** Do not widen the destination (no
`/.well-known/*`, no wildcard host). The closed-door `302` on `/` in step 6 is the check that nothing else
is bypassed. Cloudflare's page also says a path with no rule of its own "will inherit any rules set for" its
parent, so whether the bypass app reaches below the exact path (`.../jwks.json/x`) is **unknown**; the
origin-side ingress rule in step 2 is anchored to the exact path, so even if it did, nothing but the JWKS
gets through, and step 6 probes that path too.

### 2. Tunnel and DNS

Create usr's **own** remotely-managed tunnel and keep its token (the node-app tier's per-app token tunnel;
see [node-app's "The gate"](../node-app/README.md#the-gate--a-per-app-token-tunnel-not-the-shared-host-tunnel)).
Set its ingress through the API as in [`gate/README.md` step 1b](../../gate/README.md#1b-tunnel-ingress-remotely-managed),
with the service being the compose service name -- but with **two rules for the hostname, JWKS first**:

```jsonc
{
  "config": {
    "ingress": [
      {
        // The JWKS path ONLY, and NO `access` block. First match wins, so this must come before the next rule.
        "hostname": "<USR_HOSTNAME>",
        "path": "^/\\.well-known/jwks\\.json$",
        "service": "http://usr:8432",
        "originRequest": { "httpHostHeader": "<USR_HOSTNAME>" }
      },
      {
        // Everything else: the Access-validated rule, exactly as node-app's gate describes. <USR_AUD> is app 1a's.
        "hostname": "<USR_HOSTNAME>",
        "service": "http://usr:8432",
        "originRequest": {
          "access": { "required": true, "teamName": "<TEAM>", "audTag": ["<USR_AUD>"] },
          "httpHostHeader": "<USR_HOSTNAME>"
        }
      },
      { "service": "http_status:404" }   // catch-all MUST stay last
    ]
  }
}
```

**Why the JWKS needs its own rule.** The `access` block makes `cloudflared` validate an Access JWT before it
proxies, per rule. Read from `cloudflared`'s source (`ingress/middleware/jwtvalidator.go` and
`ingress/ingress.go`, `master`, 2026-10-02): a request with **no** `Cf-Access-Jwt-Assertion` header is
refused with a bare `403` (`cloudflared` logs the reason "no access token in request"; the client sees only
the status), rules match on `hostname` and a **regex** `path`, the first match wins, and the validator is
attached per rule. A request let through by the Bypass policy is not
authenticated, so it carries no Access JWT (**inferred** -- Cloudflare's documentation does not say either
way); on the hostname-wide rule it would be refused `403` at the origin side and the consumer would never
get the keys. The JWKS-only rule (an anchored regex, so nothing else matches it) lets exactly that path
through, and every other path is still validated at the origin. Step 6's `200` on the JWKS URL is the proof;
a `403` there means this rule is missing, misordered, or carries an `access` block. As in the gate runbook,
the ingress `PUT` replaces the whole array, and read it back afterwards -- but note that the gate runbook's
read-back check ("each hostname rule carries its own `originRequest.access`") applies to the
**hostname-wide** rule only. The JWKS rule is deliberately without one; do not "fix" it.

Then create the **proxied CNAME** for `<USR_HOSTNAME>` to `<TUNNEL_ID>.cfargotunnel.com`
([`gate/README.md` step 1c](../../gate/README.md#1c-dns)) -- only now that both Access apps exist.

### 3. The stack directory and `.env`

On `<BOX>`, from a clone of this repo:

```bash
sudo mkdir -p /opt/stacks/usr/deploy && sudo chown "$USER" /opt/stacks/usr -R
cp servers/usr/compose.yaml.example                       /opt/stacks/usr/compose.yaml
cp servers/usr/.env.example                               /opt/stacks/usr/.env
cp servers/node-app/publish/deploy-pull.sh.example        /opt/stacks/usr/deploy/deploy-pull.sh
cp servers/node-app/publish/set-tunnel-token.sh.example   /opt/stacks/usr/deploy/set-tunnel-token.sh
chmod 600 /opt/stacks/usr/.env

# usr's database lives here, outside the stack dir (the compose bind-mounts it; USR_PG_DATA_DIR changes it):
sudo mkdir -p /opt/usr/postgres
```

Fill `/opt/stacks/usr/.env` (every `<PLACEHOLDER>` in it):

- `IMAGE` -- usr's image, without the tag; `REGISTRY_USER` + `REGISTRY_TOKEN` -- a `read:packages` token for
  an account that can read that private package. Nothing else about the registry needs changing for
  `ghcr.io`.
- `POSTGRES_PASSWORD` -- `openssl rand -hex 24`. **Hex only** (it is spliced into a URL unescaped).
- `USR_SSO_COOKIE_DOMAIN=<COOKIE_DOMAIN>` -- must be a parent of `<USR_HOSTNAME>` **and** of every app that
  should sign in through usr, or those apps never receive the cookie. `USR_PUBLIC_URL=https://<USR_HOSTNAME>`.
- `CLOUDFLARE_TUNNEL_TOKEN` -- do **not** paste it. Pipe it through node-app's helper so it never touches
  shell history or a session transcript:

  ```bash
  printf '%s' "$TOKEN" | STACK_DIR=/opt/stacks/usr EXPECTED_TUNNEL_ID=<TUNNEL_ID> \
    bash /opt/stacks/usr/deploy/set-tunnel-token.sh
  ```

  (`bash <path>`, because a file copied from a `.example` is not executable.)

Pin the `cloudflared` image tag in `compose.yaml` (`<CLOUDFLARED_TAG>`): the deploy timer never pulls the
sidecar, so an unpinned one never updates.

### 4. Bring it up, then install the deploy timer

```bash
cd /opt/stacks/usr
grep '^REGISTRY_TOKEN=' .env | cut -d= -f2- | docker login ghcr.io -u <REGISTRY_USER> --password-stdin
docker compose --profile tunnel up -d
docker compose ps           # usr and postgres both "healthy"; cloudflared up
```

`usr` runs its migrations at boot, so the first start takes a little while (the healthcheck's
`start_period` is 30 s) and may restart once or twice while Postgres is still initialising its data
directory: a refused connection fails the migrations, the process exits, and `restart: unless-stopped`
starts it again. `usr` deliberately has no `depends_on: postgres` (see the compose file for why: node-app's
`deploy-pull.sh` reads `docker compose config --images usr` and must see exactly one image -- **do not add
one**). Postgres's data should now be under `/opt/usr/postgres` in a version subdirectory.

Then the image auto-swap, which is node-app's, used as is ([its section](../node-app/README.md#the-deploy-pull-timer-image-auto-swap)).
Run this block from your clone of this repo again (the commands above ended in `/opt/stacks/usr`).
Replace every `<app>` with `usr`, set `<user>` (a member of the `docker` group -- root-equivalent, read
node-app's trust note) in the service, and keep `STACK_DIR="/opt/stacks/usr"`, `SERVICE="usr"` in the script:

```bash
DEPLOY_USER=<USER>      # the account the unit drops to: a member of the docker group
sed -i 's/<app>/usr/g' /opt/stacks/usr/deploy/deploy-pull.sh
sudo cp servers/node-app/publish/deploy-pull.service.example /etc/systemd/system/usr-deploy.service
sudo cp servers/node-app/publish/deploy-pull.timer.example   /etc/systemd/system/usr-deploy.timer
sudo sed -i "s/<app>/usr/g; s/<user>/$DEPLOY_USER/g" /etc/systemd/system/usr-deploy.service /etc/systemd/system/usr-deploy.timer
sudo systemctl daemon-reload && sudo systemctl enable --now usr-deploy.timer
bash /opt/stacks/usr/deploy/deploy-pull.sh      # "usr: ... unchanged ..." on a current box
```

The timer pulls and recreates **only the `usr` service**. Postgres and the sidecar are never swapped by
it: a Postgres major upgrade is a deliberate, manual migration of the data directory, not something this
stack does for you.

### 5. Backups: usr's database goes to another host

Do this before anything real is stored. A dump kept only on `<BOX>` is lost with it -- and if `<BOX>` is
also where your other backups land, losing it loses both. The database is not just the roster and the role
assignments: it also holds usr's **JWT signing key** (usr generates it on first use and loads it from the
database afterwards, as described above). Lose the database
and usr mints a new key, so every identity cookie already issued stops verifying as soon as a consumer
refetches the JWKS. A dump therefore also holds the signing key -- treat it as a secret.

- **Mechanism: a `pg_dump` from the Postgres container, on a systemd timer on `<BOX>`** (a oneshot service
  and timer in the shape of node-app's `deploy-pull` pair), nightly:

  ```bash
  # in a small script run by that service. Write to a .partial and rename, so a half-written dump is never shipped.
  docker compose -f /opt/stacks/usr/compose.yaml exec -T postgres \
    pg_dump -U usr -d usr --format=custom > <STAGING_DIR>/usr-$(date +%F).dump.partial \
    && mv <STAGING_DIR>/usr-$(date +%F).dump.partial <STAGING_DIR>/usr-$(date +%F).dump
  ```

  (`pg_dump` runs inside the container over its local socket, so it needs no password -- **inferred**
  from the image's documented default of trusting local connections; step 6's restore-list check is what
  proves it.) In a systemd unit a literal `%` must be written `%%`; a script file avoids that.
- **Destination: a host other than `<BOX>`, your choice** (`<BACKUP_HOST>`), shipped by whatever backup path
  you already run. Which host and how are an operator decision this repo does not make.
- **Retention** is yours too; a dump is small, but it is a copy of identity data.

### 6. Verify

From a session with **no Access cookie** (not logged in), and **before** anything else points at usr:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<USR_HOSTNAME>/                              # 302 -- the door is shut
curl -s -o /dev/null -w "%{http_code}\n" https://<USR_HOSTNAME>/api/health                    # 302 -- not bypassed either
curl -s -o /dev/null -w "%{http_code}\n" https://<USR_HOSTNAME>/.well-known/jwks.json         # 200 -- the one bypass
curl -s -o /dev/null -w "%{http_code}\n" https://<USR_HOSTNAME>/.well-known/jwks.json/x       # 302 (or 403) -- never 200
curl -s https://<USR_HOSTNAME>/.well-known/jwks.json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).keys.length))"   # 1
```

- The `302`s are the closed door ([`gate/README.md` step 2](../../gate/README.md#2-verify--the-closed-door-probe)):
  inspect the `Location` of the first and confirm it names `<USR_HOSTNAME>`. A `200` on `/` is a failed
  rollout -- stop. **The bypass is exactly `/.well-known/jwks.json`**, so everything but that path must
  `302`; this is the check. The `/x` probe just below the JWKS path should `302` too; a `403` there means
  Cloudflare's bypass app reached below the exact path and the origin-side rule refused it -- nothing is
  exposed, but narrow the bypass app's destination. A `200` there is a failed rollout.
- The JWKS must be `200` with **one** key. (The first request is what generates and stores the key, so
  this is also the first use.) A `403` means the origin-side check refused it -- see step 2's JWKS rule.
- **The first dump exists on the destination**, is non-empty, and lists cleanly:
  `docker run --rm -i postgres:18 pg_restore --list < usr-<DATE>.dump | head`.

### 7. The welcome screen: the initial admin and the break-glass credentials

> **Until this step is done usr is in open mode: every request that reaches it is a root identity.** Access is
> the only thing in front of it. Do this right after step 6 and before any app is pointed at usr.

Open `https://<USR_HOSTNAME>/` in a browser (through Access). With no users and no credentials yet, usr shows
the welcome screen: enter an email, a username and a password (a name is optional). That creates the initial
admin -- a real user holding the seeded `usr:admin` role -- and the **break-glass local credentials** linked
to it. **Record the break-glass credentials in your password manager, never in a file, a ticket, or a chat.**
Afterwards setup is closed (a second attempt is refused) and usr is no longer in open mode.

### 8. Roles: `ac:admin` and `ac:viewer`

Apps are just string namespaces (no registration), so `ac` exists once a role names it. In usr's UI, on the
Roles page, create two roles: app `ac`, names `admin` and `viewer`. Then open your own user's page and tick
`ac:admin` in its per-app role list. Assigning roles **replaces the user's whole role set**, so leave
`usr:admin` ticked as well or you drop it.

Check: the Roles page lists `ac:admin` and `ac:viewer`, and your user shows `ac:admin` as well as `usr:admin`.

### 9. Verify from the consumer

From the host that runs the app that will verify usr's tokens:

```bash
docker exec <CONSUMER_CONTAINER> node -e "fetch('https://<USR_HOSTNAME>/.well-known/jwks.json').then(r=>r.json()).then(j=>console.log(j.keys.length))"   # 1
```

This crosses the same path a consumer's own JWKS fetch takes: the public hostname, the Cloudflare edge,
the JWKS Access bypass, this project's tunnel. (The consumer needs `node` for this one-liner; any HTTP
client does the same job.)

## Updating

- **New usr image** -- nothing by hand: the timer's next tick pulls it and recreates `usr`. Run
  `deploy/deploy-pull.sh` yourself to do it now. Migrations run at boot, so a new image migrates the
  database before it serves.
- **`compose.yaml` / `.env`** -- `docker compose --profile tunnel up -d` (a plain `up -d` would not reach
  the profiled sidecar).
- **`usr-deploy.{service,timer}`** -- re-copy and `sudo systemctl daemon-reload`.

### Changing the Postgres password

The password in `.env` only takes effect when the data directory is first initialised. Changing
`POSTGRES_PASSWORD` later makes usr's `DATABASE_URL` stop matching the database, and usr cannot connect.
To change it for real, set the new password in the database first
(`docker compose exec postgres psql -U usr -d usr -c "ALTER USER usr PASSWORD '<new>'"`; it connects over the
container's local socket, the same **inferred** no-password path as the dump in step 5), then in `.env`,
then `docker compose --profile tunnel up -d`.

## Removing

```bash
sudo systemctl disable --now usr-deploy.timer
sudo rm /etc/systemd/system/usr-deploy.{service,timer} && sudo systemctl daemon-reload
cd /opt/stacks/usr && docker compose --profile tunnel down      # the database survives: it is a host directory
```

Then remove the two Access apps, the tunnel ingress and DNS record in Cloudflare (the runbook in reverse).
`/opt/usr/postgres` is **not** removed by `down`: delete it yourself only when you mean to destroy
the roster and the signing key.

## Container lockdown: not applied here

node-app recommends a [container lockdown](../node-app/README.md#container-lockdown-recommended)
(`read_only`, `cap_drop: [ALL]`, `no-new-privileges`, a read-only config mount). This stack applies only its
log caps. usr's image has no `USER` line, so it runs as root, and nobody has run it under a read-only root
filesystem: node-app's "Check first" step (`docker run --rm --read-only --tmpfs /tmp <image> ...`) has not
been done for usr, and Postgres's entrypoint needs privileges `cap_drop: [ALL]` would remove (**inferred**).
Do that check before adding any of it; usr is the identity provider for every app behind it, which is a
reason to.

## What is verified, and what is not

- **Verified here:** the compose file parses as YAML, and (at authoring time, by a throwaway script -- not a
  committed test; this repo has no CI) every `${VAR}` it uses is defined in `.env.example`, `usr` has no
  `depends_on` and publishes no port, and the variable names node-app's scripts read are present; every
  statement about usr's behaviour was read from its source at the commit above and checked by an independent
  audit (the file-and-line citations are deliberately not published here, as this repo is public); every
  statement about the shape is checked against
  `servers/node-app/` at this repo's `297bcf1` (the scripts are reused unchanged, and `config --images usr`
  returning a single image without `depends_on` was **read from `docker/compose`'s source**, not run);
  the `cloudflared` behaviours in step 2 were read from its source.
- **Not verified -- no real rollout has run yet:** `docker compose config` itself (no Docker on the machine
  this was written on), any of steps 1-9 on a real box and a real Cloudflare account, the bind-mounted data
  directory's ownership on first boot (`postgres` creates its own `18/` subdirectory under it -- **unknown**
  until step 4 shows it), that `pg_dump` over the container socket needs no password (**inferred**), that a
  Bypass-policy request carries no Access JWT (**inferred**), and whether the bypass app reaches below the
  exact JWKS path (**unknown**; the `/x` probe in step 6 answers it). Per [`CLAUDE.md`](../../CLAUDE.md), a
  green parse is not proof the deploy works; the first real consumer's run is.

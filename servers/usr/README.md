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
`<USR_AUD>` (your Access team name and the usr Access app's AUD tag), `<TUNNEL_ID>`, `<ACCOUNT_ID>`,
`<BOX>` (the host that runs this stack), `<BACKUP_HOST>` (a different host), `<CONSUMER_CONTAINER>`.

## What usr is, and what this project assumes

Read from usr's own repo (private, a different org's) at commit `bffa881` -- the full SHA and what was
checked are in [`CONTEXT.md`](../../CONTEXT.md#sources-what-each-scaffold-was-extracted-from). Paths below
are in that repo.

| Fact this stack relies on | Source |
|---|---|
| The image is a **private** ghcr package, published `linux/amd64` only, as `latest` on every push to `main` (plus `sha-<short>` and semver tags) | `.github/workflows/publish-image.yml:39-44, 51` |
| Runtime is `node:24-alpine`, `PORT=8432`, `CMD node dist/server/index.js`; **no `HEALTHCHECK`**, no `USER` | `Dockerfile:13, 25, 29` |
| Migrations are applied at boot, before the server listens | `src/server/index.ts:9` |
| Postgres is `postgres:18`, data mounted at the **parent** `/var/lib/postgresql` (18+ uses a version subdirectory); its own compose publishes `127.0.0.1:8432` and `127.0.0.1:5434`, which this stack does not | `docker-compose.yml:16-17, 32, 38-42` |
| `DATABASE_URL`, default `postgres://usr:usr@postgres:5432/usr` | `src/server/lib/db.ts:11, 15` |
| `GET /api/health` -> `{"ok":true}`, **unauthenticated** | `src/server/app.ts:51, 118` |
| `GET /.well-known/jwks.json`: unauthenticated, `Cache-Control: public, max-age=300`, **one** ES256 key, generated on first use and persisted in `app_settings` | `src/server/app.ts:129-132`, `src/server/lib/jwt.ts:104-127` |
| SSO is **off unless `USR_SSO_COOKIE_DOMAIN` is set**; cookie `nz_id` on that domain, `HttpOnly; Secure; SameSite=Lax`; TTL `USR_SSO_TOKEN_TTL`, default 30m | `src/server/lib/sso.ts:11-12, 46-53, 73-90` |
| First run: with no credentials, no OAuth, no API key and no users, usr is in **open mode** (every request is a root identity) until the welcome screen's `POST /api/auth/setup` creates the initial admin (holding `usr:admin`) and the break-glass local credentials | `src/server/lib/auth.ts:123-148, 199-210`, `src/server/app.ts:92`, `src/server/routes/auth.ts:99-124` |
| Apps are string namespaces, no registration; role names match `^[a-z0-9][a-z0-9._-]{0,63}$`; `POST /api/roles` (a duplicate is a 400) and `GET /api/roles?app=` need `roles:write` / `roles:read`, which `usr:admin` satisfies (`*`) | usr `README.md` "Concepts", `src/server/lib/roles.ts:17, 40-72`, `src/server/routes/roles.ts:31-43`, `src/server/lib/roles-lookup.ts:69-70` |
| `PUT /api/users/:id/roles {roleIds}` **replaces** the user's whole role set | `src/server/lib/roles.ts:105-114`, `src/server/routes/users.ts:67-74` |

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
specific rule takes precedence" ([Access application paths](https://developers.cloudflare.com/cloudflare-one/policies/access/app-paths/),
read 2026-10-02), so this path is bypassed and everything else on the hostname stays behind app 1a.

**The bypass is exactly `/.well-known/jwks.json`, nothing wider.** Do not widen the destination (no
`/.well-known/*`, no wildcard host). The closed-door `302` on `/` in step 6 is the check that nothing else
is bypassed.

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
refused with `403` "no access token in request", rules match on `hostname` and a **regex** `path`, the
first match wins, and the validator is attached per rule. A request let through by the Bypass policy is not
authenticated, so it carries no Access JWT (**inferred** -- Cloudflare's documentation does not say either
way); on the hostname-wide rule it would be refused `403` at the origin side and the consumer would never
get the keys. The JWKS-only rule (an anchored regex, so nothing else matches it) lets exactly that path
through, and every other path is still validated at the origin. Step 6's `200` on the JWKS URL is the proof;
a `403` there means this rule is missing, misordered, or carries an `access` block. As in the gate runbook,
the ingress `PUT` replaces the whole array, and read it back afterwards.

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
  an account that can read that private package (a classic PAT). Nothing else about the registry needs
  changing for `ghcr.io`.
- `POSTGRES_PASSWORD` -- `openssl rand -hex 24`. **Hex only** (it is spliced into a URL unescaped).
- `USR_SSO_COOKIE_DOMAIN=<COOKIE_DOMAIN>` -- must be a parent of `<USR_HOSTNAME>` **and** of every app that
  should sign in through usr, or those apps never receive the cookie. `USR_PUBLIC_URL=https://<USR_HOSTNAME>`.
- `CLOUDFLARE_TUNNEL_TOKEN` -- do **not** paste it. Pipe it through node-app's helper so it never touches
  shell history or a session transcript:

  ```bash
  printf '%s' "$TOKEN" | STACK_DIR=/opt/stacks/usr EXPECTED_TUNNEL_ID=<TUNNEL_ID> \
    /opt/stacks/usr/deploy/set-tunnel-token.sh
  ```

Pin the `cloudflared` image tag in `compose.yaml` (`<CLOUDFLARED_TAG>`): the deploy timer never pulls the
sidecar, so an unpinned one never updates.

### 4. Bring it up, then install the deploy timer

```bash
cd /opt/stacks/usr
grep '^REGISTRY_TOKEN=' .env | cut -d= -f2- | docker login ghcr.io -u <REGISTRY_USER> --password-stdin
docker compose --profile tunnel up -d
docker compose ps           # usr and postgres both "healthy"; cloudflared up
```

`usr` becomes healthy only after Postgres does and its migrations have run, so the first start takes a
little while (the healthcheck's `start_period` is 30 s). Postgres's data should now be under
`/opt/usr/postgres` in a version subdirectory.

Then the image auto-swap, which is node-app's, used as is ([its section](../node-app/README.md#the-deploy-pull-timer-image-auto-swap)).
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
assignments: it also holds usr's **JWT signing key** (the `app_settings` row, section `jwt`; usr generates
it on first use and loads it from there afterwards -- `src/server/lib/jwt.ts:104-122`). Lose the database
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
curl -s https://<USR_HOSTNAME>/.well-known/jwks.json | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>console.log(JSON.parse(s).keys.length))"   # 1
```

- The two `302`s are the closed door ([`gate/README.md` step 2](../../gate/README.md#2-verify--the-closed-door-probe)):
  inspect the `Location` of the first and confirm it names `<USR_HOSTNAME>`. A `200` on `/` is a failed
  rollout -- stop. **The bypass is exactly `/.well-known/jwks.json`**, so everything but that path must
  `302`; this is the check.
- The JWKS must be `200` with **one** key. (The first request is what generates and stores the key, so
  this is also the first use.) A `403` means the origin-side check refused it -- see step 2's JWKS rule.
- **The first dump exists on the destination**, is non-empty, and lists cleanly:
  `docker run --rm -i postgres:18 pg_restore --list < usr-<DATE>.dump | head`.

### 7. The welcome screen: the initial admin and the break-glass credentials

> **Until this step is done usr is in open mode: every request that reaches it is a root identity**
> (`src/server/lib/auth.ts:199-210`). Access is the only thing in front of it. Do this right after step 6
> and before any app is pointed at usr.

Open `https://<USR_HOSTNAME>/` in a browser (through Access). `GET /api/auth/status` reports
`setupRequired: true` and the SPA shows the welcome screen: enter an email, a username and a password (a
name is optional). That creates the initial admin -- a real user holding the seeded `usr:admin` role -- and the
**break-glass local credentials** linked to it. **Record the break-glass credentials in your password
manager, never in a file, a ticket, or a chat.** Afterwards setup is closed (`POST /api/auth/setup` is a
`400` once configured) and usr is no longer in open mode.

### 8. Roles: `ac:admin` and `ac:viewer`

Apps are just string namespaces (no registration), so `ac` exists once a role names it. In usr's UI
(the Roles page, `#/roles`), create two roles: app `ac`, names `admin` and `viewer` (names must match
`^[a-z0-9][a-z0-9._-]{0,63}$`). Then open your own user (Users page, `#/users/<uuid>`) and tick `ac:admin`
in its per-app role list. If you do it by API
instead (`POST /api/roles` with `{"app":"ac","name":"admin"}`, a repeat is a `400` "already exists";
`PUT /api/users/<user uuid>/roles` with `{"roleIds":[...]}`): that `PUT` **replaces the user's whole role
set**, so include `usr:admin`'s id as well (`GET /api/roles?app=usr`) or you drop it.

Check: `GET /api/roles?app=ac` (as admin) lists `admin` and `viewer`, and your user's roles include
`ac:admin`.

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

## What is verified, and what is not

- **Verified here:** the compose file parses as YAML; every statement about usr's behaviour is cited to
  its source at the commit above and was read there; every statement about the shape is checked against
  `servers/node-app/` at this repo's `297bcf1` (the scripts are reused unchanged, and their variable
  names are matched in `.env.example`); the `cloudflared` behaviours in step 2 were read from its source.
- **Not verified -- no real rollout has run yet:** `docker compose config` (no Docker on the machine this
  was written on), any of steps 1-9 on a real box and a real Cloudflare account, the bind-mounted data
  directory's ownership on first boot (`postgres` creates its own `18/` subdirectory under it -- **unknown**
  until step 4 shows it), that `pg_dump` over the container socket needs no password (**inferred**), and that
  a Bypass-policy request carries no Access JWT (**inferred**). Per [`CLAUDE.md`](../../CLAUDE.md), a green
  parse is not proof the deploy works; the first real consumer's run is.

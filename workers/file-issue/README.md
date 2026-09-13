# file-issue Worker

An Access-gated Cloudflare Worker that files (or finds) a GitHub issue in one click from a
static page -- without the page itself ever holding a GitHub token. Extracted from
`Rackbops/Tooling`'s tools-site Toolchain page (`Rackbops/Tooling#638`), where it turns a
"File issue" prefilled-form link into a same-origin `POST` that resolves in place.

Unlike [`gate/`](../../gate/) and [`servers/<name>/`](../../servers/), this isn't an origin
server behind the loopback + tunnel gate -- it deploys straight to Cloudflare's edge and adds a
route onto a hostname **already** covered by an existing Access application (the same one
gating your static site or app). If you don't have that yet, do [`gate/README.md`](../../gate/)
first; this Worker is additive to it, not a replacement.

## Why a Worker, not a route on your app server

A static site (or one behind a `servers/<name>/` base server that doesn't run app code) has
nowhere to hold a secret. A small Worker on the same Access-gated hostname needs no new Access
app, no cross-origin `allowed_hosts` config, and no second tunnel -- Access already refuses an
unauthenticated request before it reaches this route at all. The Worker still verifies the
`Cf-Access-Jwt-Assertion` itself (defence in depth, in case the edge config is ever wrong), and
checks a same-origin `Sec-Fetch-Site` header (CORS headers alone don't stop a cross-site POST
from being *delivered*, only from being *read* by the calling page's JS).

## Files

| File | What it is |
|---|---|
| [`src/index.ts.example`](src/index.ts.example) | The `fetch` handler: path/method/cross-site/JWT/input/repo-allowlist checks, then dedupe-search-then-create. |
| [`src/accessJwt.ts.example`](src/accessJwt.ts.example) | Verifies the Access JWT (RS256 signature, `aud`, `iss`, `exp`) via `jose`'s `createRemoteJWKSet`. |
| [`src/allowlist.ts.example`](src/allowlist.ts.example) | Input validation: `repo` shape, title-prefix allowlist, body/title length caps, label allowlist. **Adapt the `labels.json` import** -- see "What to adapt" below. |
| [`src/github.ts.example`](src/github.ts.example) | The GitHub Search + REST calls: exact-title dedupe, then create, plus the read-only Contents-API calls the "Read routes" section below uses. |
| [`src/toolchain.ts.example`](src/toolchain.ts.example) | Pure helpers for the "Read routes" below: the manifest listing, the two allowed Contents paths, the filed-issues search shape. No `fetch`, no env access. |
| [`test/*.test.ts.example`](test/) + [`test/support.ts.example`](test/support.ts.example) | The real test suite (JWT verification, input validation, the full handler end to end) -- runs inside the actual Workers runtime via `@cloudflare/vitest-pool-workers`, not a Node approximation. |
| [`package.json.example`](package.json.example) | Dependencies (`jose`) and devDependencies (`wrangler`, `vitest`, `@cloudflare/vitest-pool-workers`, `typescript`, `eslint`). Not committed as `package.json` here -- see "No lint/test CI on this repo" in the repo `README.md`. |
| [`wrangler.toml.example`](wrangler.toml.example) | Worker name, routes (two hostnames -- delete the second if you only have one), and the two non-secret `[vars]`. |
| [`tsconfig.json.example`](tsconfig.json.example), [`eslint.config.js.example`](eslint.config.js.example), [`vitest.config.ts.example`](vitest.config.ts.example), [`worker-configuration.d.ts.example`](worker-configuration.d.ts.example) | Toolchain config -- copy as-is, drop `.example`. |

## Bring it up

1. Copy every `.example` file into your app repo under (for example) `worker/`, dropping the
   `.example` suffix (`src/index.ts.example` -> `src/index.ts`, `package.json.example` ->
   `package.json`, etc.). There is no `package-lock.json.example` -- `npm ci` in step 4
   generates a real one from `package.json`, same as any other npm project.
2. Fill in `wrangler.toml`'s placeholders: `<WORKER_NAME>`, the route(s) (`<HOSTNAME_n>` /
   `<ZONE_n>` -- delete the second route entirely if you only have one hostname), and the two
   `[vars]` (`ALLOWED_REPOS`, `ALLOWED_TITLE_PREFIXES` -- see "Configuration" below).
3. Fill in `package.json`'s `<PACKAGE_NAME>`.
4. **Before running anything below, do the "What to adapt" step for `src/allowlist.ts`'s
   `labels.json` import** (see that section) -- skip it and `wrangler deploy`'s bundling step
   fails to resolve the import in a fresh repo with no `labels.json` three directories up.
5. `npm ci`, then `npx wrangler login` (once per machine) and `npx wrangler deploy`.
6. Set the secrets (never committed, never in `wrangler.toml`) -- the first three are always
   needed; `GITHUB_CONTENTS_TOKEN` only if you're using the "Read routes" below:
   ```bash
   npx wrangler secret put GITHUB_TOKEN
   npx wrangler secret put ACCESS_TEAM_DOMAIN
   npx wrangler secret put ACCESS_AUD
   npx wrangler secret put GITHUB_CONTENTS_TOKEN   # only if you copied src/toolchain.ts.example
   ```
   - **`GITHUB_TOKEN`** -- a fine-grained GitHub PAT, repository access limited to exactly the
     repos in `ALLOWED_REPOS`, permissions **Issues: Read and write** only. Nothing broader.
   - **`ACCESS_TEAM_DOMAIN`** -- your Zero Trust team domain (`<team>.cloudflareaccess.com`).
   - **`ACCESS_AUD`** -- the AUD tag of the Access application already gating this hostname
     (Cloudflare Zero Trust dashboard -> Access -> Applications -> your app -> Overview).
   - **`GITHUB_CONTENTS_TOKEN`** -- see "Read routes" below.
7. Verify:
   ```bash
   curl -sI https://<your-hostname>/api/file-issue    # expect 302 (the Access redirect), never content
   ```
   Then a real click from your page: it should resolve in place (no new tab) and show the
   filed/found issue; a second click for the same finding should return the existing issue, not
   create a duplicate.

## Configuration (`wrangler.toml`'s `[vars]`, not secrets)

- **`ALLOWED_REPOS`** -- comma-separated `owner/name` list. The Worker checks every request's
  `repo` field against this **server-side**, never trusting the client -- a request naming a
  repo not in this list gets a 403 before any GitHub call. Committed (not secret): an allowlist
  is meant to be reviewable in a PR diff.
- **`ALLOWED_TITLE_PREFIXES`** -- comma-separated list of required title prefixes, applied to
  every repo in `ALLOWED_REPOS` alike. A request whose title doesn't start with one of these is
  refused with a 400. **Matched as a literal string prefix, and any trailing space you include is
  part of it.** `"repo:${repo} is:issue ..."` aside, this is a plain `String.startsWith` check: a
  request title matches if it starts with the *exact characters* of one configured prefix, space
  included. If your own title-generating code always writes a space after the prefix (as in
  `"Toolchain: upgrade Cargo..."`), set the prefix here as `"Toolchain: "` (trailing space, inside
  the quotes) to match what you actually intend the visible, human-facing prefix to be -- an
  easy copy/paste mistake to drop, since a trailing space is invisible in most editors and this
  file's own comments and PR/issue text can silently eat it. Dropping it doesn't reject anything
  (a shorter prefix without the space still matches the same titles, since they still start with
  those characters) -- it just means the configured value no longer matches what you can visibly
  see as the intended prefix, which is confusing to debug later, not a runtime break. Both vars
  parse to an empty list when unset -- **fail closed**: an empty
  `ALLOWED_REPOS`/`ALLOWED_TITLE_PREFIXES` rejects every request, it does not silently allow
  everything.

## What to adapt

- **`src/allowlist.ts`'s `labels.json` import.** The extracted version reads
  `../../../labels.json` -- Tooling's own org-wide label standard, three directories up from
  where this file sits in that repo. You almost certainly don't have that file at that path;
  replace the import and `ALLOWED_LABELS`'s construction with your own label source (a hardcoded
  array is fine if you don't have a shared org-wide label standard).
- **The GitHub `User-Agent` string** in `src/github.ts` (`"tools-site-file-issue-worker"`) --
  cosmetic, but give it a name describing *your* Worker rather than leaving Tooling's.
- **`wrangler.toml`'s second route** -- delete it if your site only has one hostname.
- **The `<MAINTAINER>` placeholder** in a couple of source comments (dated design-decision notes
  like "repo-generic by design (`<MAINTAINER>` amendment, ...)") -- purely a comment-level
  attribution stub, no runtime effect either way. Fill it in with whoever made that call in your
  copy, or leave the literal placeholder text in place; nothing reads it at runtime.
- **If you're using the "Read routes" below**, `src/toolchain.ts.example`'s five placeholders:
  `<OWNER>/<STORE_REPO>` (the repo holding the data files), `<STORE_DIR>` (the directory in it),
  `<STANDARD_REPO>` (the repo holding the one hardcoded standard file), `<STANDARD_PATH>` (its
  path), and `<FEATURE>` (the route prefix segment, e.g. `toolchain` -> `/api/toolchain/*`) in
  `wrangler.toml`'s two extra routes and `src/index.ts`'s `TOOLCHAIN_PREFIX` constant. Not using
  the read routes at all? Delete `src/toolchain.ts`, the two `/api/<FEATURE>/*` route lines, the
  toolchain-related imports/`Env` field/functions in `src/index.ts` and `src/github.ts`, and
  `test/toolchain.test.ts`.

## Rotation

Mint the new fine-grained PAT on GitHub first, `wrangler secret put GITHUB_TOKEN` with the new
value (this overwrites the old one immediately -- no grace period), confirm one filing works,
then revoke the old PAT. `ACCESS_TEAM_DOMAIN`/`ACCESS_AUD` only need re-setting if the Access
application is ever recreated (its AUD changes) or the team domain changes -- both rare.
Widening `ALLOWED_REPOS` later means re-minting the token with the new repo added to its own
scope too, or the Worker's allowlist would let through a repo the token itself can't act on (a
502 from GitHub, not a security hole, but confusing to debug).

## Testing (yours to run -- see "No lint/test CI on this repo" in the repo README)

The test suite is real and runs inside the actual Workers runtime (`@cloudflare/vitest-pool-workers`,
not a Node approximation) -- deliberate for a write path with a secret: `Request`/`Response`/
`fetch`/WebCrypto behave exactly as they will in production. After copying and adapting the
files above: `npm ci`, then `npm run build` (typecheck), `npm run lint`, `npm test`. Wire these
into **your own** repo's CI -- this template repo runs none of it itself.

One known transitive dependency issue at time of extraction: `@cloudflare/vitest-pool-workers`
pulls in a `sharp<0.35.4` (high-severity advisory) via `miniflare`'s dev-time image tooling.
`package.json.example`'s `overrides.sharp` pins the fixed version -- keep it (or re-check
whether it's still needed) rather than dropping it as unexplained boilerplate.

## Read routes (`/api/<FEATURE>/*`, optional)

`src/toolchain.ts.example` + the GET dispatch in `src/index.ts.example` add four more `GET`
routes on this **same** Worker, behind the **same** Access application and hostname(s) as
`/api/file-issue` above. They exist for one purpose: **a static page reading a private repo's
files without ever holding a GitHub token in the browser** -- the same reason `/api/file-issue`
exists for *writing* an issue, just for *reading* data instead.

| Route | Returns |
|---|---|
| `GET /api/<FEATURE>/manifest` | `{schemaVersion: 2, generated, hosts: [{host, file}]}` -- a directory listing of `<STORE_DIR>` on `<OWNER>/<STORE_REPO>`'s `main`, filtered to `toolchain-inventory-<host>.json` names, sorted by host. |
| `GET /api/<FEATURE>/sidecar/<host>` | The raw sidecar JSON for `<host>`, byte-for-byte. `<host>` is validated against `^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$` before any path is formed -- anything else is `404`, never a GitHub call. |
| `GET /api/<FEATURE>/filed` | `{schemaVersion: 1, generated, issues: [{number, title, url}] \| null}` from a live GitHub issues search (`<STANDARD_REPO>`, open, titled `<TITLE_PREFIX>...`). `issues: null` (not a `502`) on any upstream failure -- a genuine empty result is `issues: []`, a failed search is `null`, and a caller can tell the two apart. |
| `GET /api/<FEATURE>/standard` | The raw `<STANDARD_PATH>` from `<STANDARD_REPO>`'s `main`, byte-for-byte. |

**Two fixed paths, never a general proxy.** A fine-grained GitHub PAT cannot itself be scoped to
a single path within a repo -- once it can read a repo's contents at all, it can read any file in
it. So the path allowlist has to live in *this Worker's own code*, not in the token: one directory
listing, one filename pattern under it, one hardcoded standard-file path. `sidecarPath` in
`toolchain.ts` is the ONLY function that turns a caller-supplied string into a GitHub path, and it
either returns one of a small, enumerable set of paths or refuses (`null`) outright -- there is no
code path here that echoes an arbitrary caller-supplied path segment into a GitHub URL. Do not
widen this into a general "fetch any path" proxy; add a new named route (with its own fixed path)
instead.

**A second fine-grained PAT, `GITHUB_CONTENTS_TOKEN`** -- **Contents: read** only, scoped to
**exactly** `<OWNER>/<STORE_REPO>` and `<STANDARD_REPO>`, separate from `GITHUB_TOKEN`'s Issues
read/write scope above, so a compromise of either token can't do the other's job. Mint and rotate
it the same way as `GITHUB_TOKEN` (see "Rotation" below).

**Order per request**, exactly: method/route dispatch -> Access JWT verify (`401`, the same check
`/api/file-issue` uses) -> `caches.default` lookup -> upstream GitHub call -> `Cache-Control:
max-age=60` on a cacheable result -> `ctx.waitUntil(cache.put(...))`. **The JWT is verified before
the cache is ever consulted** -- a request with no valid JWT gets `401` even when a fresh, valid
cached response already exists for that exact URL, so the cache can never become a way to read
this data unauthenticated. Any upstream non-2xx (other than `filed`'s degraded `issues: null`
path) is `502 {"error":"upstream"}`, with the real GitHub response body and headers never
forwarded to the client, so a private repo's contents can't leak through an error message.

**The 60-second cache window is this Worker's, not the only cache in play.** A page calling these
routes from behind Cloudflare should fetch with `cache: "no-store"`: a zone's own Browser Cache
TTL setting can rewrite this Worker's `Cache-Control: max-age=60` up to whatever that zone allows
on a cache HIT at the edge, well past 60 seconds -- `no-store` on the calling `fetch()` forces the
browser to always revalidate, so this Worker's own 60-second window is the only cache that
matters.

**Verify after any deploy or secret change:**

```bash
curl -sI https://<your-hostname>/api/<FEATURE>/manifest   # no Access cookie -> the Access redirect (302), never live data
```

**Which direction fixes flow.** Same rule as `/api/file-issue` above: a behavior fix (JWT
verification, the path allowlist, the GitHub API wrapping) belongs in the repo that actually has a
test suite and CI watching this code first, then gets ported back into these `.example` files with
the same placeholder substitutions -- never the other way around. A defect intrinsic to this
template's own scaffolding (a broken placeholder, a wrong instruction in "Bring it up") is fixed
here directly, since there is no live copy to prove it against.

## Known consumers

- `Rackbops/Tooling`'s `tools-site/worker/` -- the source this was extracted from
  (`Rackbops/Tooling#661` for `/api/file-issue`, `Rackbops/Tooling#667` E2/C1 for the read routes).
  Canonical vs. adapted-copy relationship, and which direction fixes flow, is recorded in that
  repo's `tools-site/README.md`.

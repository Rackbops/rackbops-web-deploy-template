# file-issue read routes (optional add-on)

Four `GET /api/<FEATURE>/*` routes for the file-issue Worker (see [`../README.md`](../README.md)),
on the same Worker and behind the same Access application. Nothing in the default copy mentions
them: a filer-only consumer copies none of this directory.

## Adding it to a copy of the Worker

Do the default copy's bring-up first (`../README.md`, "Bring it up"), then:

1. Copy these files into the same places in your Worker, dropping `.example`:
   `read-routes/src/toolchain.ts.example` -> `src/toolchain.ts`,
   `read-routes/src/readGithub.ts.example` -> `src/readGithub.ts`,
   `read-routes/src/readRoutes.ts.example` -> `src/readRoutes.ts`,
   `read-routes/test/toolchain.test.ts.example` -> `test/toolchain.test.ts`.
2. Fill the placeholders: `<OWNER>/<STORE_REPO>` (the repo holding the data files), `<STORE_DIR>`
   (the directory in it), `<STANDARD_REPO>` (the repo holding the one hardcoded standard file),
   `<STANDARD_PATH>` (its path) and `<TITLE_PREFIX>` (the title prefix the `filed` route searches
   for; the same value as `ALLOWED_TITLE_PREFIXES`) in `src/toolchain.ts` and the test, and
   `<FEATURE>` (the route prefix segment, e.g. `toolchain` -> `/api/toolchain/*`) in
   `src/readRoutes.ts` (`READ_ROUTES_PREFIX` and the `console.warn` log prefixes), the test, and
   `wrangler.toml`. The test also uses `<HOSTNAME_1>`; fill it with your first hostname. Placeholders
   left in comments (`<OWNER>`, `<STORE_REPO>`, `<STANDARD_REPO>`) are cosmetic.
3. `src/index.ts`: add the import and the `Env` field, and one dispatch branch in `fetch`:
   ```ts
   import { READ_ROUTES_PREFIX, handleReadRoute } from "./readRoutes";

   // in `interface Env`:
   GITHUB_CONTENTS_TOKEN: string;

   // in `fetch`, after the /api/file-issue branch (rename `_ctx` to `ctx`):
   if (url.pathname.startsWith(READ_ROUTES_PREFIX)) {
     return handleReadRoute(request, env, ctx, url);
   }
   ```
4. `wrangler.toml`: add to `routes` (and delete the second line if you have one hostname):
   ```toml
   { pattern = "<HOSTNAME_1>/api/<FEATURE>/*", zone_name = "<ZONE_1>" },
   { pattern = "<HOSTNAME_2>/api/<FEATURE>/*", zone_name = "<ZONE_2>" },
   ```
5. `vitest.config.ts`: add `GITHUB_CONTENTS_TOKEN: "test-github-contents-token"` to the miniflare
   `bindings` (the test sends it upstream and asserts it never reaches a response).
6. Set the secret: `npx wrangler secret put GITHUB_CONTENTS_TOKEN` (see below for its scope).
7. `npm run build`, `npm run lint`, `npm test` -- the read-route tests are in `test/toolchain.test.ts`.

`src/readGithub.ts` imports `API`, `headers`, `readError` and `isSearchItems` from the default
`src/github.ts`, which exports them for this purpose.

## What the routes are

**Who may read.** The read routes require a valid Access JWT but, unlike `POST /api/file-issue`,
do **not** check `ALLOWED_EMAILS`: any principal the Access application admits (including a
service token) can read what they serve. That matches `tools-site/worker`. If your Access
application admits more people than should see the private repo's data, add the same
`isAllowedEmail` check to the GET handler.

`read-routes/src/toolchain.ts.example`, `readRoutes.ts.example` and `readGithub.ts.example` add four more `GET`
routes on this **same** Worker, behind the **same** Access application and hostname(s) as
`/api/file-issue`. They exist for one purpose: **a static page reading a private repo's
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
it the same way as `GITHUB_TOKEN` (see "Rotation" in [`../README.md`](../README.md)).

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

**Which direction fixes flow.** A behavior fix (JWT
verification, the path allowlist, the GitHub API wrapping) belongs in the repo that actually has a
test suite and CI watching this code first, then gets ported back into these `.example` files with
the same placeholder substitutions -- never the other way around. A defect intrinsic to this
template's own scaffolding (a broken placeholder, a wrong instruction in "Bring it up") is fixed
here directly, since there is no live copy to prove it against.


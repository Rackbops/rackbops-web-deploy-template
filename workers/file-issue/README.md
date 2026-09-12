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
| [`src/github.ts.example`](src/github.ts.example) | The GitHub Search + REST calls: exact-title dedupe, then create. |
| [`test/*.test.ts.example`](test/) + [`test/support.ts.example`](test/support.ts.example) | The real test suite (JWT verification, input validation, the full handler end to end) -- runs inside the actual Workers runtime via `@cloudflare/vitest-pool-workers`, not a Node approximation. |
| [`package.json.example`](package.json.example) | Dependencies (`jose`) and devDependencies (`wrangler`, `vitest`, `@cloudflare/vitest-pool-workers`, `typescript`, `eslint`). Not committed as `package.json` here -- see "No lint/test CI on this repo" in the repo `README.md`. |
| [`wrangler.toml.example`](wrangler.toml.example) | Worker name, routes (two hostnames -- delete the second if you only have one), and the two non-secret `[vars]`. |
| [`tsconfig.json.example`](tsconfig.json.example), [`eslint.config.js.example`](eslint.config.js.example), [`vitest.config.ts.example`](vitest.config.ts.example), [`worker-configuration.d.ts.example`](worker-configuration.d.ts.example) | Toolchain config -- copy as-is, drop `.example`. |

## Bring it up

1. Copy every `.example` file into your app repo under (for example) `worker/`, dropping the
   `.example` suffix (`src/index.ts.example` -> `src/index.ts`, `package.json.example` ->
   `package.json`, etc.).
2. Fill in `wrangler.toml`'s placeholders: `<WORKER_NAME>`, the route(s) (`<HOSTNAME_n>` /
   `<ZONE_n>` -- delete the second route entirely if you only have one hostname), and the two
   `[vars]` (`ALLOWED_REPOS`, `ALLOWED_TITLE_PREFIXES` -- see "Configuration" below).
3. Fill in `package.json`'s `<PACKAGE_NAME>`.
4. `npm ci`, then `npx wrangler login` (once per machine) and `npx wrangler deploy`.
5. Set the three secrets (never committed, never in `wrangler.toml`):
   ```bash
   npx wrangler secret put GITHUB_TOKEN
   npx wrangler secret put ACCESS_TEAM_DOMAIN
   npx wrangler secret put ACCESS_AUD
   ```
   - **`GITHUB_TOKEN`** -- a fine-grained GitHub PAT, repository access limited to exactly the
     repos in `ALLOWED_REPOS`, permissions **Issues: Read and write** only. Nothing broader.
   - **`ACCESS_TEAM_DOMAIN`** -- your Zero Trust team domain (`<team>.cloudflareaccess.com`).
   - **`ACCESS_AUD`** -- the AUD tag of the Access application already gating this hostname
     (Cloudflare Zero Trust dashboard -> Access -> Applications -> your app -> Overview).
6. Verify:
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
  refused with a 400. Both vars parse to an empty list when unset -- **fail closed**: an empty
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

## Known consumers

- `Rackbops/Tooling`'s `tools-site/worker/` -- the source this was extracted from
  (`Rackbops/Tooling#661`). Canonical vs. adapted-copy relationship, and which direction fixes
  flow, is recorded in that repo's `tools-site/README.md`.

# The image ratchet -- build the real image, boot it, assert it works

A test that builds your app's **actual Docker image** and boots it with **no volumes and no
config file** (an empty/fresh state, close to a real fresh install), then asserts it comes up
and serves at least a health check. Unlike a unit test, this catches the class of bug that only
exists in the real container: a file the build forgot to `COPY`, a path that resolves in `tsx
watch` but not in the compiled `dist/`, a default that only "works" because a dev `.env`
happened to set it. This doc explains the pattern and its two genuinely app-specific pieces
(there's no `.yml.example` here, unlike `release.yml.example` -- see why below); adapt it rather
than copy it verbatim.

Reference consumer: `Rackbops/kenzen`'s `.github/workflows/image-ratchet.yml`
(`packages/server/src/image-assert.test.ts` for the unit-level half, `scripts/assert-image.mjs`
for the real-image half) -- itself the Kenzen-scoped heir of `Rackbops/artifact-console`'s own
`image-ratchet.yml`, simplified since Kenzen has no plugin host (no import-map ABI to pin).

## The two pieces that are genuinely yours to write

1. **The runner.** Building a real image on every PR is expensive and, if you use a **self-hosted
   runner**, carries a real constraint: **never attach a self-hosted GitHub Actions runner to a
   PUBLIC repo** -- a runner is arbitrary code execution on whatever box it's attached to, and a
   public repo means anyone who can open a PR can run code on your machine. artifact-console is a
   private repo and builds its ratchet on Rackbops' own self-hosted `docker` pool
   (`Rackbops/Tooling#393`/`#437`); Kenzen started there too, but moved its ratchet to
   `ubuntu-latest` when the repo went public, for exactly this reason. A public repo needs
   `ubuntu-latest` (or an equivalently sandboxed hosted runner), at the cost of a slower,
   less-cached build.
2. **The assertion script.** What "works" means is app-specific -- Kenzen's checks `/healthz`
   plus that the SPA shell loads; yours might check a different endpoint, a expected response
   shape, or a specific error path. Write a small script (any language your image build already
   needs) that curls/fetches what your app actually needs to prove, and fails loud with the
   container's logs on any timeout -- don't let a silent hang read as success.

## The shape (structure from Kenzen's workflow, which now runs it on `ubuntu-latest` -- adapt every specific)

```yaml
on:
  pull_request:

concurrency:
  group: image-ratchet-${{ github.ref }}
  cancel-in-progress: true

jobs:
  ratchet:
    runs-on: [self-hosted, docker]   # <-- swap for ubuntu-latest on a PUBLIC repo, see above
    timeout-minutes: 15              # a pool slot is shared; GitHub's default is 360 minutes
    steps:
      - uses: actions/checkout@v4
      - name: Build the real image
        run: docker build -t <app>:ci .
      - name: Boot it with an empty config (no volumes -> defaults, ephemeral state)
        run: |
          docker rm -f <app>-ratchet >/dev/null 2>&1 || true
          docker run -d --name <app>-ratchet -p 127.0.0.1:<PORT>:<PORT> <app>:ci
          # poll until healthy or time out -- see Kenzen's image-ratchet.yml for the loop
      - name: Assert the image actually works
        run: <YOUR-ASSERTION-SCRIPT> http://127.0.0.1:<PORT>
      - name: Container logs
        if: always()
        run: docker logs <app>-ratchet || true
      - name: Teardown
        if: always()
        run: docker rm -f <app>-ratchet || true
```

## Why this stays a `.md`, not a `.yml.example`

`release.yml.example` in this same directory genuinely is a template -- swap `<app>`/`<owner>`
and it runs. This pattern isn't: the runner choice and the assertion logic are real decisions
every consumer has to make for itself, not blanks to fill in. Shipping a `.yml.example` that
looked copy-pasteable would invite exactly the runner mistake this doc's first section warns
against (defaulting to `self-hosted` without checking repo visibility) on a repo where that's
wrong. Read Kenzen's real workflow file linked above for the complete, working version.

## See also

- [`release.yml.example`](release.yml.example) -- the sibling file that ships as a real template.
- [`../README.md`](../README.md) -- the base `node-app` server tier this CI pattern deploys.
- `Rackbops/Tooling` `docs/disposable-docker-ci-runners.md` -- the disposable runner pool, if
  your app is private and wants the same shape artifact-console uses.

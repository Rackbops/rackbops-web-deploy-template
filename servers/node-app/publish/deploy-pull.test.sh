#!/usr/bin/env bash
# Standalone test harness for deploy-pull.sh.example
# (Rackbops/rackbops-web-deploy-template#108). Not a template .example a consumer copies -- this is
# a maintainer check, run by hand (this repo has no lint/test CI, per CLAUDE.md), the same way
# set-tunnel-token.sh.example is exercised by set-tunnel-token.test.sh.
#
# Run: bash servers/node-app/publish/deploy-pull.test.sh
#
# The SUT hardcodes STACK_DIR/SERVICE as `<app>`-placeholder assignments meant for a consumer's
# own hand-edit (unlike set-tunnel-token.sh.example, which reads STACK_DIR from the environment) --
# so each case runs against a TEMP COPY of the .example file with those two lines substituted,
# exactly the edit a real consumer makes after copying it. `docker` itself is a shim on PATH:
# every invocation is logged, and each subcommand answers from env vars the case sets (see the
# shim's own header, below).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT_SRC="$SCRIPT_DIR/deploy-pull.sh.example"

pass_count=0
fail_count=0

pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# make_stack: fresh temp STACK_DIR with a minimal .env -- no REGISTRY_TOKEN, so the SUT's own
# registry-login step is a no-op (this test is about the recreate decision, not registry auth).
make_stack() {
  local dir
  dir="$(mktemp -d)"
  printf 'IMAGE=ghcr.io/rackbops/example\nIMAGE_TAG=latest\n' > "$dir/.env"
  echo "$dir"
}

# make_sut <stack-dir>: a temp copy of the SUT with STACK_DIR set to <stack-dir> and SERVICE set
# to "example" -- the exact two-line hand-edit a real consumer makes after copying the .example
# file, done here by `sed` instead of by hand so each case gets an isolated STACK_DIR. Echoes the
# temp script's path.
make_sut() {
  local dir="$1" tmp
  tmp="$(mktemp)"
  sed -e "s|^STACK_DIR=\"/opt/stacks/<app>\".*|STACK_DIR=\"$dir\"|" \
      -e "s|^SERVICE=\"<app>\".*|SERVICE=\"example\"|" \
      "$SUT_SRC" > "$tmp"
  chmod +x "$tmp"
  echo "$tmp"
}

# make_docker_shim: a directory on PATH holding a fake `docker`. Every invocation is appended to
# $DOCKER_CALL_LOG as "docker <argv>". Each subcommand's answer comes from env vars the case sets
# before invoking the SUT:
#   IMG_REF           -- `compose config --images` output (default: a fixed ref).
#   WANT_ID           -- `image inspect --format {{.Id}}` output. An explicitly empty string is
#                        itself a case (docker succeeded, but the id is empty).
#   WANT_INSPECT_FAIL -- if set, `image inspect` exits 1 instead (a real inspect failure).
#   CONTAINER_ID      -- `compose ps -q` output; unset/empty means no container exists.
#   HAVE_ID           -- `inspect --format {{.Image}} <cid>` output (only reached when
#                        CONTAINER_ID is non-empty).
#   UP_FAIL           -- if set, `compose up ...` exits 1 instead of 0.
# Echoes the shim directory.
make_docker_shim() {
  local dir
  dir="$(mktemp -d)"
  cat > "$dir/docker" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
: "${DOCKER_CALL_LOG:?DOCKER_CALL_LOG must be set}"
echo "docker $*" >> "$DOCKER_CALL_LOG"
IMG_REF="${IMG_REF:-ghcr.io/rackbops/example:latest}"
case "$1" in
  compose)
    case "$2" in
      config) echo "$IMG_REF" ;;
      pull) exit 0 ;;
      ps)
        if [[ -n "${CONTAINER_ID:-}" ]]; then echo "$CONTAINER_ID"; fi
        exit 0
        ;;
      up)
        if [[ -n "${UP_FAIL:-}" ]]; then exit 1; fi
        exit 0
        ;;
      *) echo "docker-shim: unhandled compose subcommand: $*" >&2; exit 99 ;;
    esac
    ;;
  image)
    case "$2" in
      inspect)
        if [[ -n "${WANT_INSPECT_FAIL:-}" ]]; then exit 1; fi
        printf '%s\n' "${WANT_ID-}"
        ;;
      *) echo "docker-shim: unhandled image subcommand: $*" >&2; exit 99 ;;
    esac
    ;;
  inspect)
    # Container inspect: docker inspect --format '{{.Image}}' <cid>. Only reached when the SUT
    # already found a non-empty container id.
    printf '%s\n' "${HAVE_ID-}"
    ;;
  login)
    exit 0
    ;;
  *)
    echo "docker-shim: unhandled invocation: $*" >&2
    exit 99
    ;;
esac
SHIM
  chmod +x "$dir/docker"
  echo "$dir"
}

# ---------------------------------------------------------------------------
echo "=== Case 1: running image equals the tag -> nothing to do, no up ==="
stack="$(make_stack)"; sut="$(make_sut "$stack")"; shim_dir="$(make_docker_shim)"; log="$(mktemp)"
output="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log" WANT_ID="sha256:abc" CONTAINER_ID="c1" \
  HAVE_ID="sha256:abc" bash "$sut" 2>&1)"
rc=$?

if [[ $rc -eq 0 ]]; then pass "case1: exits 0"; else fail "case1: expected exit 0, got $rc (output: $output)"; fi
if grep -qi "unchanged" <<<"$output"; then pass "case1: prints 'unchanged'"; else fail "case1: output doesn't mention unchanged: $output"; fi
if grep -q "compose up" "$log"; then fail "case1: compose up was called"; else pass "case1: compose up was never called"; fi
rm -rf "$stack" "$shim_dir"; rm -f "$sut" "$log"

# ---------------------------------------------------------------------------
echo "=== Case 2: tag moved, up succeeds -> recreates once ==="
stack="$(make_stack)"; sut="$(make_sut "$stack")"; shim_dir="$(make_docker_shim)"; log="$(mktemp)"
output="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log" WANT_ID="sha256:new" CONTAINER_ID="c1" \
  HAVE_ID="sha256:old" bash "$sut" 2>&1)"
rc=$?

if [[ $rc -eq 0 ]]; then pass "case2: exits 0"; else fail "case2: expected exit 0, got $rc (output: $output)"; fi
if grep -qi "recreating" <<<"$output"; then pass "case2: prints 'recreating'"; else fail "case2: output doesn't mention recreating: $output"; fi
up_calls="$(grep -c "compose up" "$log" || true)"
if [[ "$up_calls" -eq 1 ]]; then pass "case2: compose up called exactly once"; else fail "case2: compose up called $up_calls times"; fi
rm -rf "$stack" "$shim_dir"; rm -f "$sut" "$log"

# ---------------------------------------------------------------------------
echo "=== Case 3: tag moved, up fails -> exit non-zero; a second run (container still on the old"
echo "            image) recreates again -- the retry the before/after tag comparison prevented ==="
stack="$(make_stack)"; sut="$(make_sut "$stack")"; shim_dir="$(make_docker_shim)"; log1="$(mktemp)"
output1="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log1" WANT_ID="sha256:new" CONTAINER_ID="c1" \
  HAVE_ID="sha256:old" UP_FAIL=1 bash "$sut" 2>&1)"
rc1=$?

if [[ $rc1 -ne 0 ]]; then pass "case3: first run exits non-zero"; else fail "case3: expected non-zero exit, got 0 (output: $output1)"; fi
if grep -qi "recreating" <<<"$output1"; then pass "case3: first run attempted to recreate"; else fail "case3: first run didn't attempt recreate: $output1"; fi

# Second run: same tag (WANT_ID unchanged), container STILL on the old image -- the failed
# recreate never actually swapped it, so HAVE_ID stays "old". A before/after TAG comparison would
# see the tag's own id unchanged since the FIRST run's own before/after and report "unchanged"
# forever; comparing the running container instead catches the mismatch and retries.
log2="$(mktemp)"
output2="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log2" WANT_ID="sha256:new" CONTAINER_ID="c1" \
  HAVE_ID="sha256:old" bash "$sut" 2>&1)"
rc2=$?

if [[ $rc2 -eq 0 ]]; then pass "case3: second run exits 0 (up succeeds this time)"; else fail "case3: second run expected exit 0, got $rc2 (output: $output2)"; fi
if grep -qi "recreating" <<<"$output2"; then pass "case3: second run attempted to recreate again (the retry)"; else fail "case3: second run said unchanged instead of retrying: $output2"; fi
rm -rf "$stack" "$shim_dir"; rm -f "$sut" "$log1" "$log2"

# ---------------------------------------------------------------------------
echo "=== Case 4: no container exists -> recreates ==="
stack="$(make_stack)"; sut="$(make_sut "$stack")"; shim_dir="$(make_docker_shim)"; log="$(mktemp)"
output="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log" WANT_ID="sha256:new" CONTAINER_ID="" bash "$sut" 2>&1)"
rc=$?

if [[ $rc -eq 0 ]]; then pass "case4: exits 0"; else fail "case4: expected exit 0, got $rc (output: $output)"; fi
if grep -qi "recreating" <<<"$output"; then pass "case4: recreates when no container exists"; else fail "case4: didn't recreate: $output"; fi
if grep -q "^docker inspect " "$log"; then fail "case4: container inspect was called despite no container"; else pass "case4: container inspect skipped when no container id"; fi
rm -rf "$stack" "$shim_dir"; rm -f "$sut" "$log"

# ---------------------------------------------------------------------------
echo "=== Case 5: image inspect returns empty -> fails loudly, no up ==="
stack="$(make_stack)"; sut="$(make_sut "$stack")"; shim_dir="$(make_docker_shim)"; log="$(mktemp)"
output="$(PATH="$shim_dir:$PATH" DOCKER_CALL_LOG="$log" WANT_ID="" CONTAINER_ID="c1" \
  HAVE_ID="sha256:old" bash "$sut" 2>&1)"
rc=$?

if [[ $rc -ne 0 ]]; then pass "case5: exits non-zero"; else fail "case5: expected non-zero exit, got 0 (output: $output)"; fi
if grep -qiE "no id|refusing" <<<"$output"; then pass "case5: error names the empty-inspect failure"; else fail "case5: error message unclear: $output"; fi
if grep -q "compose up" "$log"; then fail "case5: compose up was called despite the empty inspect"; else pass "case5: compose up never called"; fi
rm -rf "$stack" "$shim_dir"; rm -f "$sut" "$log"

# ---------------------------------------------------------------------------
echo
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]

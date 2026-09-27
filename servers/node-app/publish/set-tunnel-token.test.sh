#!/usr/bin/env bash
# Standalone test harness for set-tunnel-token.sh.example (Rackbops/Tooling#776). Not a template
# .example a consumer copies -- this is a maintainer check, run by hand (this repo has no lint/test
# CI, per CLAUDE.md), the same way publish-scp.ps1.example is parse-checked by hand before a commit.
#
# Run: bash servers/node-app/publish/set-tunnel-token.test.sh
#
# Each fake "token" is base64 of {"a":"acct","t":"<tunnel-id>","s":"<padded-secret>"} -- the
# secret is padded so the encoded string actually satisfies the SUT's own
# `eyJ[A-Za-z0-9+/=_-]{100,}` extraction regex; the minimal `"s":"secret"` shape from the issue
# comes out at 92 chars total, 8 short of the 103 the regex requires, so a short secret would make
# every "correct token" case fail extraction before ever reaching the tunnel-id check it's meant to
# test. Real Cloudflare tunnel tokens are this long in practice (their own secret field is a long
# random string) -- the padding here just reproduces that length, not a different shape.
#
# NOTE on where this proves what it claims: `chmod`/`stat` mode bits are only meaningful on a real
# POSIX filesystem. A Windows/MSYS (Git Bash) filesystem silently ignores chmod and always reports
# 644; a WSL DrvFs mount (/mnt/c/...) always reports 777 regardless of chmod too. This harness was
# run on Melody under WSL's OWN native filesystem (a temp dir under WSL's Linux root, not /mnt/*),
# which is a real Linux kernel + real POSIX permission bits -- the same semantics as the Linux box
# this script actually deploys to. Running it from plain Git Bash still exercises every assertion
# except the mode-bit one, which will read back the underlying (wrong) filesystem's value instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$SCRIPT_DIR/set-tunnel-token.sh.example"

pass_count=0
fail_count=0

pass() { pass_count=$((pass_count + 1)); echo "PASS: $1"; }
fail() { fail_count=$((fail_count + 1)); echo "FAIL: $1"; }

# assert_no_stray_tmp <label> <stack-dir>: no leftover .env.XXXXXX temp file after a refusal --
# the EXIT trap in set-tunnel-token.sh.example should always clean one up, success or failure.
assert_no_stray_tmp() {
  local label="$1" dir="$2" strays
  strays="$(find "$dir" -maxdepth 1 -name '.env.??????' 2>/dev/null)"
  if [[ -z "$strays" ]]; then
    pass "$label: no stray temp file left in $dir"
  else
    fail "$label: stray temp file(s) left behind: $strays"
  fi
}

# tok_json '<tunnel-id>' -> base64 of {"a":"acct","t":"<tunnel-id>","s":"<48 A's>"} (148 chars
# total, well past the SUT's 103-char floor -- see header note).
tok_json() {
  local tid="$1"
  printf '{"a":"acct","t":"%s","s":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}' "$tid" | base64 -w0
}

TID_GOOD="3b1a29e7-c9f9-4d4b-b318-b2a8dc78a9cf"
TID_OTHER="00000000-0000-0000-0000-000000000000"
TOKEN_GOOD="$(tok_json "$TID_GOOD")"
TOKEN_WRONG_TUNNEL="$(tok_json "$TID_OTHER")"

ENV_BODY='IMAGE=ghcr.io/rackbops/example
IMAGE_TAG=latest
REGISTRY=ghcr.io
REGISTRY_USER=exampleuser
REGISTRY_TOKEN=exampletoken
CLOUDFLARE_TUNNEL_TOKEN=<CLOUDFLARE_TUNNEL_TOKEN>'

# make_stack: fresh temp STACK_DIR with a .env seeded from $ENV_BODY (or $1 if given). Echoes the
# dir path.
make_stack() {
  local dir body
  dir="$(mktemp -d)"
  body="${1:-$ENV_BODY}"
  printf '%s\n' "$body" > "$dir/.env"
  echo "$dir"
}

# ---------------------------------------------------------------------------
echo "=== Case 1: a correct token is written; .env stays 600; other lines untouched; no echo ==="
stack="$(make_stack)"
orig_other_lines="$(grep -v '^CLOUDFLARE_TUNNEL_TOKEN=' "$stack/.env")"
output="$(printf '%s' "$TOKEN_GOOD" | STACK_DIR="$stack" EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?

if [[ $rc -eq 0 ]]; then pass "case1: exits 0"; else fail "case1: expected exit 0, got $rc (output: $output)"; fi

if grep -qF "$TOKEN_GOOD" <<<"$output"; then
  fail "case1: the token appeared in the script's own output"
else
  pass "case1: the token never appears in output"
fi

new_token_line="$(grep '^CLOUDFLARE_TUNNEL_TOKEN=' "$stack/.env" || true)"
if [[ "$new_token_line" == "CLOUDFLARE_TUNNEL_TOKEN=$TOKEN_GOOD" ]]; then
  pass "case1: .env's CLOUDFLARE_TUNNEL_TOKEN line is the new token"
else
  fail "case1: .env's token line is wrong: '$new_token_line'"
fi

new_other_lines="$(grep -v '^CLOUDFLARE_TUNNEL_TOKEN=' "$stack/.env")"
if [[ "$new_other_lines" == "$orig_other_lines" ]]; then
  pass "case1: every other .env line is byte-identical"
else
  fail "case1: other .env lines changed"
fi

mode="$(stat -c '%a' "$stack/.env")"
if [[ "$mode" == "600" ]]; then
  pass "case1: .env is mode 600"
else
  fail "case1: .env is mode $mode, not 600 (see the header note on which filesystem this needs to run on)"
fi
rm -rf "$stack"

# ---------------------------------------------------------------------------
echo "=== Case 2: a token for another tunnel is refused; .env unchanged ==="
stack="$(make_stack)"
before_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"
output="$(printf '%s' "$TOKEN_WRONG_TUNNEL" | STACK_DIR="$stack" EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?
after_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"

if [[ $rc -ne 0 ]]; then pass "case2: exits non-zero"; else fail "case2: expected non-zero exit, got 0 (output: $output)"; fi
if [[ "$before_sha" == "$after_sha" ]]; then pass "case2: .env unchanged"; else fail "case2: .env was modified"; fi
if grep -qF "$TOKEN_WRONG_TUNNEL" <<<"$output"; then fail "case2: the rejected token appeared in output"; else pass "case2: the rejected token never appears in output"; fi
assert_no_stray_tmp "case2" "$stack"
rm -rf "$stack"

# ---------------------------------------------------------------------------
echo "=== Case 3: garbage input is refused; .env unchanged ==="
stack="$(make_stack)"
before_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"
output="$(printf 'this is not a token, just some pasted nonsense\n' | STACK_DIR="$stack" EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?
after_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"

if [[ $rc -ne 0 ]]; then pass "case3: exits non-zero"; else fail "case3: expected non-zero exit, got 0 (output: $output)"; fi
if [[ "$before_sha" == "$after_sha" ]]; then pass "case3: .env unchanged"; else fail "case3: .env was modified"; fi
assert_no_stray_tmp "case3" "$stack"
rm -rf "$stack"

# ---------------------------------------------------------------------------
echo "=== Case 4: a missing STACK_DIR or EXPECTED_TUNNEL_ID gives a clear error ==="
stack="$(make_stack)"

output="$(printf '%s' "$TOKEN_GOOD" | EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then pass "case4a: missing STACK_DIR exits non-zero"; else fail "case4a: expected non-zero exit"; fi
if grep -qi "STACK_DIR" <<<"$output"; then pass "case4a: error names STACK_DIR"; else fail "case4a: error doesn't mention STACK_DIR: $output"; fi

output="$(printf '%s' "$TOKEN_GOOD" | STACK_DIR="$stack" bash "$SUT" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then pass "case4b: missing EXPECTED_TUNNEL_ID exits non-zero"; else fail "case4b: expected non-zero exit"; fi
if grep -qi "EXPECTED_TUNNEL_ID" <<<"$output"; then pass "case4b: error names EXPECTED_TUNNEL_ID"; else fail "case4b: error doesn't mention EXPECTED_TUNNEL_ID: $output"; fi
rm -rf "$stack"

# ---------------------------------------------------------------------------
echo "=== Case 5 (bonus): a .env with no existing CLOUDFLARE_TUNNEL_TOKEN= line is refused, not silently a no-op ==="
stack="$(make_stack "IMAGE=ghcr.io/rackbops/example
IMAGE_TAG=latest")"
before_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"
output="$(printf '%s' "$TOKEN_GOOD" | STACK_DIR="$stack" EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?
after_sha="$(sha256sum "$stack/.env" | cut -d' ' -f1)"
if [[ $rc -ne 0 ]]; then pass "case5: exits non-zero"; else fail "case5: expected non-zero exit, got 0 (output: $output)"; fi
if [[ "$before_sha" == "$after_sha" ]]; then pass "case5: .env unchanged"; else fail "case5: .env was modified"; fi
assert_no_stray_tmp "case5" "$stack"
rm -rf "$stack"

# ---------------------------------------------------------------------------
echo "=== Case 6: no external command's argv ever carries the token (guards the awk -v argv leak class -- Rackbops/Tooling#776 review finding) ==="
stack="$(make_stack)"
shim_dir="$(mktemp -d)"
argv_log="$(mktemp)"
# Shim every external command the script invokes: each shim logs its own argv, then execs the
# real binary. If a future edit ever puts the token on an external command's command line again
# (the exact bug this case was added for), it shows up here even though every OTHER assertion in
# this suite -- which only inspects the script's own stdout/stderr and the final .env -- would
# stay green.
for cmd in awk base64 grep tr cut mktemp chmod mv head basename; do
  real="$(command -v "$cmd")"
  cat > "$shim_dir/$cmd" <<SHIM
#!/usr/bin/env bash
printf '%s: %s\n' "$cmd" "\$*" >> "$argv_log"
exec "$real" "\$@"
SHIM
  chmod +x "$shim_dir/$cmd"
done
output="$(printf '%s' "$TOKEN_GOOD" | PATH="$shim_dir:$PATH" STACK_DIR="$stack" EXPECTED_TUNNEL_ID="$TID_GOOD" bash "$SUT" 2>&1)"
rc=$?
if [[ $rc -eq 0 ]]; then pass "case6: shimmed run still succeeds"; else fail "case6: shimmed run failed unexpectedly (rc=$rc): $output"; fi
if grep -qF "$TOKEN_GOOD" "$argv_log"; then
  fail "case6: the token appeared in an external command's argv -- $(grep -F "$TOKEN_GOOD" "$argv_log")"
else
  pass "case6: no external command's argv contains the token"
fi
rm -rf "$stack" "$shim_dir"
rm -f "$argv_log"

# ---------------------------------------------------------------------------
echo
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]

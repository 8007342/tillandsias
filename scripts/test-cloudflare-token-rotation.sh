#!/usr/bin/env bash
# @trace order:1505-iysn, openspec/changes/cloudflare-login-and-fleet-vpn/design.md (Decision 2)
# @trace openspec/changes/cloudflare-login-and-fleet-vpn/specs/cloudflare-auth/spec.md
#
# The Cloudflare OAuth bundle lives at secret/cloudflare/token and
# secret/cloudflare/refresh (refresh record written first), and a resident
# due-check rotates it under a host-wide lock from the same three entry points
# as the GitHub token (Linux tray, every lane launch, the guest listener).
#
# Arms 1-5 and the crash arm drive the PRODUCTION refresh path against the
# real tillandsias-fake-cloudflare over loopback, with an in-memory Vault seam
# (no real Vault, no real Cloudflare, no real token):
#   ARM1 20 min left -> exactly ONE grant_type=refresh_token at the fake,
#        refresh record written before the token record, later expiry
#   ARM2 two concurrent due-checks -> ONE exchange; CONTROL inside the test:
#        distinct lock names make the same checks exchange twice
#   ARM3 2 h left -> no exchange, no write (the negative control for ARM1)
#   ARM4 the fake refuses the refresh -> both old records intact, the verdict
#        names cloudflare-token-rotation-failed, no token bytes in it
#   ARM5 a forge never rotates and never touches the store (CONTROL: the same
#        store on bare metal rotates); TILLANDSIAS_HOST_KIND=forge sets it
#   ARM6 each entry point calls spawn_cloudflare_token_rotation_scheduler in
#        the NAMED function's body (not a comment), and a scratch copy with
#        that one call commented out FAILS, naming the entry point
#   +    crash between the two writes loses nothing; no token in Debug or in
#        any verdict (CONTROL: a planted token trips the check); a failed
#        refresh-record write keeps the old pair; a non-https token endpoint
#        is refused before the refresh token is sent; bounded backoff
#   POL  no policy but tray.hcl grants anything under secret/data/cloudflare/
#        and git-mirror.hcl's grants are exactly the GitHub token pair;
#        CONTROLS: a scratch copy with a cloudflare grant added to forge.hcl,
#        or a stanza added to git-mirror.hcl, FAILS naming that file
# EACH ARM MUST APPEAR AS `... ok` BY NAME: a filter that selects zero tests
# prints "0 passed" and exits 0, which is not a pass.
#
# PRE-FIX RESULT: FAILS — no Cloudflare paths, store, scheduler, tests or
# call sites existed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
MAIN="$ROOT/crates/tillandsias-headless/src/main.rs"
TRAY="$ROOT/crates/tillandsias-headless/src/tray/mod.rs"
CALL="spawn_cloudflare_token_rotation_scheduler"
FAIL=0
ok()  { printf 'ok:   %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:cloudflare-token-rotation:no-cargo"
    exit 3
fi
for f in "$MAIN" "$TRAY"; do [ -r "$f" ] || { echo "blocked:cloudflare-token-rotation:missing:$f"; exit 2; }; done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/cf-token-rotation.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

echo "[cloudflare-token-rotation] building tillandsias-fake-cloudflare..." >&2
if ! cargo build -p tillandsias-headless --bin tillandsias-fake-cloudflare >"$scratch/build-fake.log" 2>&1; then
    tail -20 "$scratch/build-fake.log"
    echo "fail:cloudflare-token-rotation:build-fake"
    exit 1
fi
FAKE_BIN="${CARGO_TARGET_DIR:-$ROOT/target}/debug/tillandsias-fake-cloudflare"
[ -x "$FAKE_BIN" ] || { echo "fail:cloudflare-token-rotation:fake-binary-missing:$FAKE_BIN"; exit 1; }
export TILLANDSIAS_FAKE_CLOUDFLARE_BIN="$FAKE_BIN"

echo "[cloudflare-token-rotation] running the arms..." >&2
out="$(cargo test -p tillandsias-headless --features tray,listen-vsock --bins cloudflare_token_rotation_ -- --include-ignored 2>&1)"
rc=$?
T="vault_bootstrap::cloudflare_token_rotation_tests"
ARMS="ARM1|cloudflare_token_rotation_fake_due_token_rotates_once_refresh_first
ARM2|cloudflare_token_rotation_fake_concurrent_checks_exchange_once
ARM3|cloudflare_token_rotation_fake_not_due_makes_no_exchange
ARM4|cloudflare_token_rotation_fake_refused_refresh_keeps_both_records
ARM5|cloudflare_token_rotation_fake_forge_never_rotates
CRASH|cloudflare_token_rotation_fake_crash_between_writes_loses_nothing
NOLEAK|cloudflare_token_rotation_never_prints_a_token
RECORDS|cloudflare_token_rotation_records_keep_refresh_off_the_token_path
WRITEFAIL|cloudflare_token_rotation_refresh_write_failure_keeps_old_pair
HTTPS|cloudflare_token_rotation_token_endpoint_must_be_https
BACKOFF|cloudflare_token_rotation_scheduler_once_and_backoff_bounded
POL|cloudflare_token_rotation_policies_keep_forges_out"
while IFS= read -r line; do
    label="${line%%|*}"; arm="${line#*|}"
    if grep -qE "^test ${T}::${arm} \.\.\. ok$" <<<"$out"; then
        ok "$label $arm"
    else
        bad "$label $arm"
    fi
done <<<"$ARMS"
if [ "$rc" -ne 0 ]; then
    grep -E "panicked|FAILED|^error" <<<"$out" | head -12
    bad "cargo test exited $rc"
fi

# ── POL controls: a mutated COPY of the policy dir must fail, naming the file ──
pol_control() {   # <label> <file-to-mutate> <stanza> <name-expected-in-failure>
    local d="$scratch/pol-$1"
    mkdir -p "$d"
    cp "$ROOT"/images/vault/policies/*.hcl "$d/"
    printf '\n%s\n' "$3" >>"$d/$2"
    local cout
    cout="$(TILLANDSIAS_TEST_POLICY_AUDIT_DIR="$d" cargo test -p tillandsias-headless --features tray,listen-vsock --bins cloudflare_token_rotation_policies_keep_forges_out 2>&1)"
    if grep -qE "^test ${T}::cloudflare_token_rotation_policies_keep_forges_out \.\.\. FAILED$" <<<"$cout" \
        && grep -q "$4" <<<"$cout"; then
        ok "POL CONTROL $1: the audit catches it and names $4"
    else
        bad "POL CONTROL $1: a mutated $2 was NOT caught (or not named)"
    fi
}
pol_control forge-glob forge.hcl 'path "secret/+/cloudflare/*" { capabilities = ["read"] }' "forge.hcl grants"
pol_control forge-wide forge.hcl 'path "secret/*" { capabilities = ["read"] }' "forge.hcl grants"
pol_control mirror-changed git-mirror.hcl 'path "secret/data/ca/proxy-cert" { capabilities = ["read"] }' "git-mirror.hcl grants changed"

# ── ARM 6: the three entry points (1489-8qd6's method) ──────────────────────
# body <file> <fn-name-regex>: the body of the first fn matching, by brace depth.
body() {
    awk -v re="$2" '
        !on && $0 ~ "fn " re "[(<]" { on = 1 }
        on {
            print
            line = $0
            gsub(/"([^"\\]|\\.)*"/, "", line)
            sub(/\/\/.*/, "", line)
            n = gsub(/\{/, "{", line); depth += n; seen += n
            depth -= gsub(/\}/, "}", line)
            if (seen && depth <= 0) exit
        }' "$1"
}
calls() { body "$1" "$2" | grep -vE '^[[:space:]]*//' | grep -c "$CALL" || true; }
check() { local n; n="$(calls "$1" "$2")"; [ "${n:-0}" -ge 1 ]; }

# The tray's call sits in the fn that starts the control socket server.
tray_fn="$(awk -v c="$CALL" '
    /^[[:space:]]*(pub(\([a-z]+\))? )?(async )?fn [a-z_]+/ { match($0, /fn [a-z_]+/); f = substr($0, RSTART + 3, RLENGTH - 3) }
    index($0, c) && $0 !~ /^[[:space:]]*\/\// { print f; exit }' "$TRAY")"
ENTRIES="TRAY|$TRAY|${tray_fn:-<none>} LANE|$MAIN|ensure_enclave_for_project GUEST|$MAIN|maybe_spawn_vsock_listener"

for e in $ENTRIES; do
    label="${e%%|*}"; rest="${e#*|}"; file="${rest%%|*}"; fn="${rest#*|}"
    if check "$file" "$fn"; then
        ok "ARM6 $label: $fn calls $CALL"
    else
        bad "ARM6 $label: $fn does NOT call $CALL — this process would never rotate the Cloudflare token"
    fi
done
# Captured first: `producer | grep -q` under pipefail reports a MATCH as a
# failure when grep exits early and the producer takes SIGPIPE.
tray_body="$(body "$TRAY" "${tray_fn:-<none>}")"
if [ -z "$tray_fn" ] || ! grep -q 'start_control_socket_server(' <<<"$tray_body"; then
    bad "ARM6 TRAY: the call is not in the tray's start-up fn (the one that starts the control socket server)"
fi
for e in $ENTRIES; do
    label="${e%%|*}"; rest="${e#*|}"; file="${rest%%|*}"; fn="${rest#*|}"
    m="$scratch/$label.rs"
    awk -v re="$fn" -v c="$CALL" '
        !on && $0 ~ "fn " re "[(<]" { on = 1 }
        on && !done && index($0, c) && $0 !~ /^[[:space:]]*\/\// { sub(/[^[:space:]]/, "// &"); done = 1 }
        { print }' "$file" > "$m"
    if cmp -s "$file" "$m"; then
        bad "ARM6 MUTATION $label: the mutation did not reach (nothing was commented out)"
    elif check "$m" "$fn"; then
        bad "ARM6 MUTATION $label: removing the call in $fn was NOT caught"
    else
        ok "ARM6 MUTATION $label: commenting out the call in $fn is caught"
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "ok:cloudflare-token-rotation:6/6+controls"
    exit 0
fi
echo "fail:cloudflare-token-rotation"
exit 1

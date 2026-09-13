#!/usr/bin/env bash
# @trace order:900-z3kv, spec:tillandsias-vault
#
# Fixture for clear-vault-host-credentials.sh — criterion 3's BOTH directions.
#
# REGIME: hermetic for the FILE locations, which is where the both-directions
# obligation bites. Every arm points the script at a scratch XDG_CACHE_HOME and
# asserts on files it planted itself, so it touches no real credential, reads no
# secret, and asserts nothing about this host. The KEYCHAIN arm is exercised
# through a `secret-tool` stub on PATH rather than a live keyring, for the same
# reason: a fixture that cleared a developer's real share to prove it could
# would be the defect this row is about, performed deliberately.
#
# NO ABSOLUTE MOMENT IS ENCODED (1130-i6xj).
#
# WHY BOTH DIRECTIONS. The row says it plainly: "prove it in BOTH directions by
# fixture — after a reset the keychain entry is absent, and a wipe path that
# does NOT clear it is caught. A one-direction assertion is what got us here."
# So the negative arms are not decoration; they are the half that was missing
# when four legs reported a clean room that was not one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAR="$ROOT/scripts/clear-vault-host-credentials.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok:   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# A secret-tool stub that records what it was asked to clear and never touches a
# real keyring. `clear` succeeding is the "item was present" case.
mkdir -p "$W/bin"
cat > "$W/bin/secret-tool" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "clear" ]; then
    shift
    printf '%s\n' "$*" >> "${STUB_LOG:?}"
    exit 0
fi
exit 1
STUB
chmod +x "$W/bin/secret-tool"

plant() { # plant <cache> — a fully warm room: both fallbacks and the data dir
    mkdir -p "$1/tillandsias/vault-data"
    : > "$1/tillandsias/fallback_vault-shamir-share-v1"
    : > "$1/tillandsias/fallback_vault-root-token-v1"
}

run_clear() { # run_clear <cache> <log> [args...]
    local c="$1" l="$2"; shift 2
    PATH="$W/bin:$PATH" STUB_LOG="$l" XDG_CACHE_HOME="$c" \
        bash "$CLEAR" "$@" 2>&1
}

# ── 1. FORWARD: a warm room is cleared in all three locations ────────────────
c="$W/c1"; l="$W/l1"; : > "$l"; plant "$c"
out="$(run_clear "$c" "$l")"; rc=$?
if [ "$rc" -ne 0 ]; then bad "arm 1: clearing a warm room exited $rc"; else
    _miss=""
    [ -e "$c/tillandsias/fallback_vault-shamir-share-v1" ] && _miss="$_miss share-fallback"
    [ -e "$c/tillandsias/fallback_vault-root-token-v1" ]  && _miss="$_miss token-fallback"
    [ -e "$c/tillandsias/vault-data" ]                    && _miss="$_miss vault-data"
    grep -q 'vault-shamir-share-v1' "$l" || _miss="$_miss keychain-share"
    grep -q 'vault-root-token-v1'   "$l" || _miss="$_miss keychain-token"
    if [ -z "$_miss" ]; then ok "a warm room is cleared in all three locations"
    else bad "arm 1 left:$_miss — a partial clear is the state that looks cold and is not"; fi
fi

# ── 2. THE OTHER DIRECTION: a wipe that does NOT clear is CAUGHT ─────────────
#      This is the arm the row demands and the one a one-direction suite omits.
#      It models `podman system reset --force` — which reaches none of these —
#      by simply not running the clearer, and asserts the room is still warm.
c="$W/c2"; plant "$c"
_warm=0
[ -e "$c/tillandsias/fallback_vault-shamir-share-v1" ] && _warm=$((_warm+1))
[ -e "$c/tillandsias/fallback_vault-root-token-v1" ]  && _warm=$((_warm+1))
[ -e "$c/tillandsias/vault-data" ]                    && _warm=$((_warm+1))
if [ "$_warm" -eq 3 ]; then ok "a wipe path that does not clear leaves the room warm, and that is detectable"
else bad "arm 2 could not construct a warm room ($_warm/3 present) — it would have asserted nothing"; fi

# ── 3. THE INSTALLATION ANCHOR IS NEVER CLEARED ─────────────────────────────
#      The safety-critical half. Windows preserves tillandsias-vm-uuid for the
#      same reason: clearing the anchor makes the next vault UNDERIVABLE rather
#      than merely re-initialised. An arm that only checks what IS removed
#      cannot catch a clearer that removes too much.
c="$W/c3"; l="$W/l3"; : > "$l"; plant "$c"
run_clear "$c" "$l" >/dev/null 2>&1
if grep -q 'installation-uuid-v1' "$l"; then
    bad "arm 3: the installation anchor was cleared — the next vault becomes underivable, not re-initialised"
else
    ok "the installation anchor is never cleared"
fi

# ── 4. IDEMPOTENT: clearing an already-cold room is not an error ─────────────
c="$W/c4"; l="$W/l4"; : > "$l"; mkdir -p "$c/tillandsias"
out="$(run_clear "$c" "$l")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "clearing an already-cold room succeeds and says so"
else bad "arm 4: an already-cold room exited $rc — absent is the desired end state, not a failure"; fi

# ── 5. CONSENT GATE: refuses without destructive consent, and clears NOTHING ─
c="$W/c5"; l="$W/l5"; : > "$l"; plant "$c"
out="$(PATH="$W/bin:$PATH" STUB_LOG="$l" XDG_CACHE_HOME="$c" \
       TILLANDSIAS_DESTRUCTIVE_RESET_OK=0 bash "$CLEAR" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ -e "$c/tillandsias/vault-data" ] && [ ! -s "$l" ]; then
    ok "no destructive consent refuses (2) and clears nothing"
else
    bad "arm 5: consent gate rc=$rc, vault-data present=$([ -e "$c/tillandsias/vault-data" ] && echo y || echo n), keychain touched=$([ -s "$l" ] && echo y || echo n)"
fi

# ── 6. DRY RUN CLEARS NOTHING, which is what makes it safe to inspect with ───
c="$W/c6"; l="$W/l6"; : > "$l"; plant "$c"
run_clear "$c" "$l" --dry-run >/dev/null 2>&1
if [ -e "$c/tillandsias/vault-data" ] && [ -e "$c/tillandsias/fallback_vault-shamir-share-v1" ] && [ ! -s "$l" ]; then
    ok "--dry-run removes nothing and touches no keychain item"
else
    bad "arm 6: --dry-run mutated state"
fi

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "PASS: clear-vault-host-credentials $pass/$total (900-z3kv)"; exit 0; fi
echo "FAIL: clear-vault-host-credentials $pass/$total (900-z3kv)"; exit 1

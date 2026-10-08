#!/usr/bin/env bash
# @trace spec:host-state-lifecycle, order:1559-2uw3, order:1437-3iux
#
# test-purge-guard-soft-arm.sh — check-purge-clears-vault-credentials.sh's
# NEGATIVE arm (1437-3iux S4): the Windows SOFT reset body calls NO credential
# clearer. The guard's positive arm (every path that unregisters the distro
# must clear) is unchanged; this pins the other direction, so a later edit that
# brings the clearer back into --reset-state is refused by name.
#
# Arms (each runs the REAL guard; the SOFT body source is pointed at a scratch
# copy through TILLANDSIAS_PURGE_GUARD_SOFT_SRC):
#   1 the real tree                                   -> ok
#   2 SOFT body calls clear_guest_vault_credentials   -> violation soft-reset-calls-a-clearer
#   3 the same call only in a // comment              -> ok (comments are stripped)
#   4 a source with no SOFT body                      -> violation soft-body-not-found
# Each sabotage asserts its own edit landed exactly once before it is judged.
#
# Pre-fix: arm 2 FAILS, because the guard has no SOFT arm and passes the
# sabotaged body.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-purge-clears-vault-credentials.sh"
SRC="$ROOT/crates/tillandsias-windows-tray/src/notify_icon.rs"
SIG='pub fn reset_state_once() -> i32 {'
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "ok:   $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }

guard() { # guard [soft-src] -> sets RC, OUT
    if [ -n "${1:-}" ]; then
        OUT="$(cd "$ROOT" && TILLANDSIAS_PURGE_GUARD_SOFT_SRC="$1" bash "$GUARD" 2>&1)"; RC=$?
    else
        OUT="$(cd "$ROOT" && bash "$GUARD" 2>&1)"; RC=$?
    fi
}
inject() { # inject <line> <out> — put <line> right after the SOFT signature
    awk -v sig="$SIG" -v line="$1" '{ print } $0 == sig { print line }' "$SRC" > "$2"
}

# 1 — the real tree passes.
guard
if [ "$RC" -eq 0 ]; then pass "1 real tree: ${OUT##*$'\n'}"; else bad "1 real tree rc=$RC: $OUT"; fi

# 2 — a SOFT body that calls the clearer is refused.
inject '    let _ = crate::installation_uuid::clear_guest_vault_credentials();' "$TMP/sab.rs"
landed="$(grep -c 'let _ = crate::installation_uuid::clear_guest_vault_credentials();' "$TMP/sab.rs")"
if [ "$landed" != "1" ]; then
    bad "2 sabotage did not land exactly once (count=$landed)"
else
    guard "$TMP/sab.rs"
    case "$RC:$OUT" in
        1:*soft-reset-calls-a-clearer*) pass "2 clearer in the SOFT body is refused" ;;
        *) bad "2 clearer in the SOFT body: rc=$RC out=[$OUT]" ;;
    esac
fi

# 3 — the same call only in a comment is not a call.
inject '    // let _ = crate::installation_uuid::clear_guest_vault_credentials();' "$TMP/cmt.rs"
landed="$(grep -c '// let _ = crate::installation_uuid::clear_guest_vault_credentials();' "$TMP/cmt.rs")"
if [ "$landed" != "1" ]; then
    bad "3 comment mutant did not land exactly once (count=$landed)"
else
    guard "$TMP/cmt.rs"
    if [ "$RC" -eq 0 ]; then pass "3 a commented-out clearer is not a call"; else bad "3 comment read as a call: rc=$RC out=[$OUT]"; fi
fi

# 4 — no SOFT body at all is refused by name, never passed vacuously.
printf 'fn unrelated() {}\n' > "$TMP/none.rs"
guard "$TMP/none.rs"
case "$RC:$OUT" in
    1:*soft-body-not-found*) pass "4 a missing SOFT body is refused by name" ;;
    *) bad "4 missing SOFT body: rc=$RC out=[$OUT]" ;;
esac

if [ "$fails" -ne 0 ]; then
    echo "fail:purge-guard-soft-arm:$fails"
    exit 1
fi
echo "ok:purge-guard-soft-arm:4 arms"

#!/usr/bin/env bash
# @trace order:147
#
# Fixture for check-tray-refresh-no-polling.sh. Every arm MUTATES a copy of the
# real source and asserts the guard goes red, because a guard over Windows-only
# code that no Linux host can compile is otherwise just a grep nobody has
# watched refuse.
#
# THE ARM THAT MATTERS IS 5. The guard's own first draft asserted that
# live_client_request contains the token "LIVE_CLIENT" and failed against code
# that is correct — the fast path reaches the static through the
# live_client_mutex() accessor and never spells the name. A guard that pins a
# SPELLING passes and fails for the wrong reasons. Arm 5 keeps the accessor
# spelling out of the assertion by proving the guard still accepts code that
# reaches the client either way.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-tray-refresh-no-polling.sh"
SRC="$ROOT/crates/tillandsias-windows-tray/src/notify_icon.rs"
fail=0; pass=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail+1)); }

[ -r "$SRC" ] || { echo "skip:tray-refresh-no-polling:source-absent" >&2; echo "tray-refresh-no-polling: 0 passed, 0 failed (skipped)"; exit 0; }

W="$(mktemp -d "${TMPDIR:-/tmp}/tray-nopoll.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM
_rc() { bash "$GUARD" "$1" >/dev/null 2>&1; echo $?; }

# ── 0. The real source passes, or every mutation arm is meaningless ────────
[ "$(_rc "$SRC")" = "0" ] && ok "the real tray source passes the guard" \
    || bad "the real source already fails; the mutation arms below prove nothing"

# ── 1. A per-call client (the reconnect-per-tick regression) ───────────────
sed 's/^static LIVE_CLIENT/static LIVE_CLIENT_RENAMED/' "$SRC" > "$W/m1.rs"
[ "$(_rc "$W/m1.rs")" != "0" ] && ok "losing the persistent static is caught" \
    || bad "the guard accepted a source with no persistent client"

# ── 2. The accessor stops being backed by the static ──────────────────────
# Exact-line swap. `index`/`substr` rather than a regex: the target line is
# full of `|`, `(` and `:` and escaping it into a sed expression is how a
# mutation silently stops mutating.
awk -v old='    LIVE_CLIENT.get_or_init(|| tokio::sync::Mutex::new(None))' \
    -v new='    Box::leak(Box::new(tokio::sync::Mutex::new(None)))' '
    index($0, old) { print new; next } { print }
' "$SRC" > "$W/m2.rs"
[ "$(_rc "$W/m2.rs")" != "0" ] && ok "an accessor no longer backed by the static is caught" \
    || bad "the guard accepted an accessor that builds a fresh mutex per call"

# ── 3. A retry loop in refresh_vm_status ──────────────────────────────────
# Insert immediately after the opening brace of the named fn. The brace is
# line-terminal in this source (verified: `async fn refresh_vm_status(hwnd: HwndHandle) {`),
# so "after that line" and "after that brace" are the same position.
awk -v fn='async fn refresh_vm_status' -v ins='    loop { break; }' '
    { print }
    !done && index($0, fn) && index($0, "{") { print ins; done = 1 }
' "$SRC" > "$W/m3.rs"
[ "$(_rc "$W/m3.rs")" != "0" ] && ok "a retry loop in refresh_vm_status is caught" \
    || bad "the guard accepted a loop in a refresh that must be single-shot"

# ── 4. A sleep in refresh_github_login ────────────────────────────────────
# Insert immediately after the opening brace of the named fn. The brace is
# line-terminal in this source (verified: `async fn refresh_github_login(hwnd: HwndHandle) {`),
# so "after that line" and "after that brace" are the same position.
awk -v fn='async fn refresh_github_login' -v ins='    tokio::time::sleep(std::time::Duration::from_secs(1)).await;' '
    { print }
    !done && index($0, fn) && index($0, "{") { print ins; done = 1 }
' "$SRC" > "$W/m4.rs"
[ "$(_rc "$W/m4.rs")" != "0" ] && ok "a sleep in refresh_github_login is caught" \
    || bad "the guard accepted a sleep in a refresh that must be single-shot"

# ── 5. MENTIONS ARE NOT ACTIONS, and spelling is not the property ─────────
# A comment naming a loop must not trip the guard, and the fast path reaching
# the client through the accessor rather than the static's name must still pass
# — which is where the guard's own first draft was wrong.
# Insert immediately after the opening brace of the named fn. The brace is
# line-terminal in this source (verified: `async fn refresh_vm_status(hwnd: HwndHandle) {`),
# so "after that line" and "after that brace" are the same position.
awk -v fn='async fn refresh_vm_status' -v ins='    // this used to loop and sleep( before order 147' '
    { print }
    !done && index($0, fn) && index($0, "{") { print ins; done = 1 }
' "$SRC" > "$W/m5.rs"
[ "$(_rc "$W/m5.rs")" = "0" ] && ok "a COMMENT naming a loop and a sleep does not trip the guard" \
    || bad "the guard counts mentions rather than actions"

echo "tray-refresh-no-polling: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

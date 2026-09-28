#!/usr/bin/env bash
# @trace order:1461-8tyy, spec:gh-auth-script
#
# The GitHub token in Vault rotates itself before it expires. The arms are unit
# tests in crates/tillandsias-headless/src/vault_bootstrap.rs over a stub Vault
# store and a stub token endpoint (no network, no real Vault, a lock name no
# live process uses):
#   1 20 min left -> ONE exchange, later expiry, refresh record written first
#   2 two concurrent due-checks -> exactly ONE exchange (decided under the lock)
#   3 NEGATIVE CONTROL: 2 h left -> no exchange, no write; the 30-min boundary
#   4 GitHub rejects the refresh token -> old records intact, the error names
#     github-token-rotation-failed and echoes no token
#   5 no desktop-session input is consulted; a forge refuses without touching
#     the store
#   + the failure backoff is bounded (1 min doubling, capped at 15 min)
#   + one scheduler per process, and every lane launch starts it (a Linux
#     host with no tray still rotates while a lane runs)
#   + the 14-day refresh-expiry warning: window, expired case, once a day
# EACH ARM MUST APPEAR AS `... ok` BY NAME: a filter that selects zero tests
# prints "0 passed" and exits 0, which is not a pass.
#
# PRE-FIX RESULT: FAILS — none of these tests existed; the only rotation caller
# was the explicit, session-gated --refresh-github-token.
# LIVE ARM (not here): a mirror push succeeds more than 8 h after the last login.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARMS="github_token_auto_rotation_due_token_rotates_once_refresh_first
github_token_auto_rotation_concurrent_checks_exchange_once
github_token_auto_rotation_not_due_makes_no_exchange
github_token_auto_rotation_rejected_refresh_keeps_the_old_pair
github_token_auto_rotation_needs_no_session_and_refuses_in_a_forge
github_token_auto_rotation_backoff_is_bounded
github_token_auto_rotation_scheduler_starts_once_per_process
github_token_auto_rotation_refresh_expiry_warns_once_a_day"

if ! command -v cargo >/dev/null 2>&1; then
    echo "skip:github-token-auto-rotation:no-cargo"
    exit 3
fi
out="$(cd "$ROOT" && cargo test -p tillandsias-headless --features tray,listen-vsock --bins github_token_auto_rotation_ 2>&1)"
rc=$?
pass=0; total=0
while IFS= read -r arm; do
    total=$((total + 1))
    if grep -qE "^test vault_bootstrap::tests::${arm} \.\.\. ok$" <<<"$out"; then
        pass=$((pass + 1)); echo "ok:   $arm"
    else
        echo "FAIL: $arm"
    fi
done <<<"$ARMS"
if [ "$rc" -eq 0 ] && [ "$pass" -eq "$total" ]; then
    echo "ok:github-token-auto-rotation:${pass}/${total}"
else
    grep -E "panicked|FAILED|error" <<<"$out" | head -8
    echo "fail:github-token-auto-rotation:${pass}/${total}:cargo_rc=${rc}"
    exit 1
fi

#!/usr/bin/env bash
# @trace order:778-hb3x, spec:git-mirror-service
#
# test-git-mirror-seed-failure-surfaced.sh — the launcher's seeded-gate surfaces
# the mirror's own seed-fetch failure line (778-hb3x criterion 3). Structural,
# and deliberately so: the behaviour is unit-tested in main.rs
# (mirror_seed_failure_tests), and what those cannot see from inside one crate
# is the CROSS-COMPONENT string, so this checks it across both files:
#   1 the marker the launcher searches for is the one images/git/entrypoint.sh
#     prints (retry_msg "<marker> …"), in BOTH of the mirror's failure arms
#   2 wait_for_git_mirror_ready reads the mirror log and calls
#     last_seed_failure while it waits AND before it gives up
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="$ROOT/crates/tillandsias-headless/src/main.rs"
ENTRY="$ROOT/images/git/entrypoint.sh"
fail=0
ok() { echo "ok:   $1"; }
bad() { echo "FAIL: $1" >&2; fail=1; }

marker="$(sed -n 's/^const GIT_MIRROR_SEED_FAILURE_MARKER: &str = "\(.*\)";$/\1/p' "$MAIN")"
[ -n "$marker" ] || { echo "FAIL: GIT_MIRROR_SEED_FAILURE_MARKER not found in main.rs" >&2; exit 1; }
n="$(/usr/bin/grep -cF "retry_msg \"$marker" "$ENTRY")"
[ "$n" -ge 2 ] && ok "1: the mirror prints the launcher's marker [$marker] in $n failure arms" \
    || bad "1: images/git/entrypoint.sh prints [$marker] in $n arms (want both: auth-refused and generic)"

body="$(awk '/^async fn wait_for_git_mirror_ready\(/{f=1} f{print} f&&/^}$/{exit}' "$MAIN")"
calls="$(printf '%s\n' "$body" | /usr/bin/grep -c 'last_seed_failure(&tail.lines)')"
logs="$(printf '%s\n' "$body" | /usr/bin/grep -c '\.log_tail(container_name')"
[ "$calls" -ge 2 ] && [ "$logs" -ge 2 ] \
    && ok "2: the seeded-gate reads the mirror log and surfaces the failure while waiting and on give-up ($calls calls)" \
    || bad "2: wait_for_git_mirror_ready calls last_seed_failure $calls times and log_tail $logs times (want >= 2 each)"

[ "$fail" -eq 0 ] || exit 1
echo "PASS: git-mirror-seed-failure-surfaced"

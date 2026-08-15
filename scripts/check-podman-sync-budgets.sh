#!/usr/bin/env bash
# @trace spec:podman-orchestration
#
# Order 714-4r6w. The synchronous podman surface must stay bounded.
#
# The primary guarantee is a TYPE, not this script: `podman_cmd_sync()` returns
# `SyncPodmanCommand`, which has no `output`/`status`/`spawn`, so a call site
# that forgets its deadline does not compile. That is stronger than any grep.
#
# This script guards the two ways around the type:
#
#   1. constructing a podman `std::process::Command` directly, bypassing
#      `podman_cmd_sync()` entirely;
#   2. `spawn_caller_owned_lifetime()`, the deliberate escape hatch for
#      genuinely long-lived children — whose call sites are COUNTED here, so the
#      exception cannot quietly grow back into the unbounded surface this packet
#      removed (34 call sites across six files, every one of them a wait that
#      could not end).
#
# Prints exactly one line matching
# `^(ok:podman-sync-bounded|violation:(direct-command|escape-hatch-grew)):[0-9]+$`
# and exits 0 only on ok.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Scan this checkout by default; the fixture points the scan at a throwaway tree
# instead, which is why the cd is conditional rather than unconditional.
if [ -z "${PODMAN_SYNC_SEARCH_ROOT:-}" ]; then
    cd "$ROOT" || exit 2
fi

# The number of caller-owned spawns that exist ON PURPOSE. Raising this number
# is a decision, and it should be made in a review, not in passing.
ALLOWED_ESCAPE_HATCHES="${PODMAN_SYNC_ESCAPE_HATCHES:-1}"
SEARCH_ROOT="${PODMAN_SYNC_SEARCH_ROOT:-crates}"

# 1) A podman command built straight from std, sidestepping the wrapper.
#
# Product code only. `crates/*/tests/` may drive podman directly: a test that
# hangs fails its own harness, not an operator's session. Comment lines are
# excluded, and so are the two existing source-shape assertions that NAME this
# pattern in order to forbid it — matching those would make the gate red for the
# code that agrees with it.
find_direct() {
    grep -rn --include=*.rs -E 'Command::new\((")?[^)]*podman' "$SEARCH_ROOT" \
        | grep -vE '/tests?/' \
        | grep -vE ':[0-9]+: *//' \
        | grep -v 'source.contains' \
        | grep -v 'fn podman_cmd_sync_std' \
        | grep -v 'src/lib.rs:'
}
direct=$(find_direct | wc -l | tr -d ' ')
if [ "$direct" -ne 0 ]; then
    echo "violation:direct-command:$direct"
    find_direct >&2
    exit 1
fi

# 2) The escape hatch, counted rather than forbidden.
hatches=$(grep -rn --include=*.rs 'spawn_caller_owned_lifetime()' "$SEARCH_ROOT" \
    | grep -v 'pub fn spawn_caller_owned_lifetime' \
    | wc -l | tr -d ' ')
if [ "$hatches" -gt "$ALLOWED_ESCAPE_HATCHES" ]; then
    echo "violation:escape-hatch-grew:$hatches"
    echo "expected at most $ALLOWED_ESCAPE_HATCHES caller-owned spawn(s); found $hatches:" >&2
    grep -rn --include=*.rs 'spawn_caller_owned_lifetime()' "$SEARCH_ROOT" \
        | grep -v 'pub fn spawn_caller_owned_lifetime' >&2
    exit 1
fi

echo "ok:podman-sync-bounded:$hatches"
exit 0

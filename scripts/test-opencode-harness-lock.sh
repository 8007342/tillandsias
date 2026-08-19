#!/usr/bin/env bash
# @trace spec:default-image, order:805-yzhw
#
# Offline fixture for order 805-yzhw: the harness-update lock must gate the
# vendor INSTALL, not merely its release.
#
# WHAT BROKE. images/default/entrypoint-forge-opencode.sh runs
# `ensure_forge_harnesses &` (backgrounded) and `require_opencode` (foreground)
# on one launch; both call curl_install_opencode, which extracts ~127MB into
# the forge's 256MB /tmp tmpfs. require_opencode took the shared lock into a
# `held` flag, logged "deferring to the in-flight harness updater" when it
# could not get it — and then ran the install ANYWAY, because `held` guarded
# only the two release calls. One extraction fits; two do not. Both died with
# `tar: Wrote only 2560 of 10240 bytes`, neither cleaned up, and the lane ended
# at a "Press any key to exit" prompt that reads to an operator as a hang.
#
# WHY EXTRACTION RATHER THAN SOURCING. lib-common.sh needs a full container
# environment (scripts/test-cache-semantics.sh:63 records the same constraint),
# so the functions under test are lifted out of the real file by name and run
# against stubs. The assertions therefore still read the shipped source text —
# editing lib-common.sh changes what this fixture executes.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

extract() {
    sed -n "/^$1() {/,/^}/p" "$LIB" | grep -q . \
        || fail "could not extract $1 from lib-common.sh (renamed?)"
    sed -n "/^$1() {/,/^}/p" "$LIB"
}

# The real functions, lifted from the shipped file.
{
    extract harness_update_lock_path
    extract harness_update_lock_acquire
    extract harness_update_lock_release
    extract harness_update_lock_wait_acquire
    extract require_opencode
    extract opencode_vendor_scratch_clean
} > "$WORK/under-test.sh"

INSTALLS="$WORK/install-count"
: > "$INSTALLS"

# --- stubs for everything the extracted functions call -----------------------
trace_lifecycle() { :; }
harness_probe() { [ -x "${2:-}" ]; }
_require_harness() { echo "$WORK/npm-fallback-opencode"; }
curl_install_opencode() {
    echo "install" >> "$INSTALLS"
    mkdir -p "$HARNESS_CURL_ROOT/opencode/bin"
    printf '#!/bin/sh\nexit 0\n' > "$HARNESS_CURL_ROOT/opencode/bin/opencode"
    chmod +x "$HARNESS_CURL_ROOT/opencode/bin/opencode"
    OC_BIN="$HARNESS_CURL_ROOT/opencode/bin/opencode"
    return 0
}
installs() { wc -l < "$INSTALLS" | tr -d ' '; }

# shellcheck source=/dev/null
. "$WORK/under-test.sh"

# ---------------------------------------------------------------------------
# Case 1 — THE DEFECT. A sibling holds the lock and never releases it. The
# lane must NOT run a second concurrent vendor install. Red before the fix:
# curl_install_opencode ran unconditionally, so this counted 1.
# ---------------------------------------------------------------------------
export HOME="$WORK/home1"
HARNESS_CURL_ROOT="$HOME/.cache/tillandsias-project/harness-curl"
mkdir -p "$HOME/.cache/tillandsias-project"
mkdir "$(harness_update_lock_path)" || fail "could not plant the sibling's lock"
# A cached binary the sibling is presumed to have produced.
mkdir -p "$HARNESS_CURL_ROOT/opencode/bin"
printf '#!/bin/sh\nexit 0\n' > "$HARNESS_CURL_ROOT/opencode/bin/opencode"
chmod +x "$HARNESS_CURL_ROOT/opencode/bin/opencode"
: > "$INSTALLS"
TILLANDSIAS_HARNESS_LOCK_WAIT_SECS=0 require_opencode >/dev/null 2>&1 || true
[ "$(installs)" = "0" ] \
    || fail "case 1: lane ran $(installs) vendor install(s) while a sibling held the lock — the lock does not gate the install"
[ "$OC_BIN" = "$HARNESS_CURL_ROOT/opencode/bin/opencode" ] \
    || fail "case 1: lane did not fall back to the sibling's cached binary (OC_BIN=$OC_BIN)"
echo "case 1 ok: a held lock prevents the second concurrent vendor install"

# ---------------------------------------------------------------------------
# Case 2 — THE CONTROL, and it is load-bearing. Without it, a require_opencode
# that simply never installs would pass case 1 while breaking every cold lane.
# An UNHELD lock must still produce exactly one install.
# ---------------------------------------------------------------------------
export HOME="$WORK/home2"
HARNESS_CURL_ROOT="$HOME/.cache/tillandsias-project/harness-curl"
mkdir -p "$HOME/.cache/tillandsias-project"
: > "$INSTALLS"
require_opencode >/dev/null 2>&1 || true
[ "$(installs)" = "1" ] \
    || fail "case 2: an unheld lock must run exactly one install, ran $(installs)"
[ ! -d "$(harness_update_lock_path)" ] \
    || fail "case 2: the lock was not released after the install"
echo "case 2 ok: an unheld lock installs exactly once and releases"

# ---------------------------------------------------------------------------
# Case 3 — the leaked vendor tree. A tree too old to be in flight is removed;
# a fresh one is left alone, because removing a sibling's live extraction is
# the same class of bug in the other direction.
# ---------------------------------------------------------------------------
stale="/tmp/opencode_install_test$$stale"
fresh="/tmp/opencode_install_test$$fresh"
mkdir -p "$stale" "$fresh"
touch -d '2 hours ago' "$stale" 2>/dev/null || touch -t "$(date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || echo 202001010000)" "$stale" 2>/dev/null || true
opencode_vendor_scratch_clean "" >/dev/null 2>&1 || true
[ ! -d "$stale" ] || { rm -rf "$stale" "$fresh"; fail "case 3: a stale vendor tree was not swept"; }
[ -d "$fresh" ] || fail "case 3: a FRESH vendor tree was swept — that can delete a sibling's in-flight extraction"
rm -rf "$fresh"
echo "case 3 ok: stale vendor trees are swept, in-flight ones are not"

echo "PASS: opencode harness-lock fixture (order 805-yzhw)"

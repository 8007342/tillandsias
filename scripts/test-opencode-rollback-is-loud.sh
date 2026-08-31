#!/usr/bin/env bash
# @trace spec:runtime-diagnostics-stream, spec:logging-accountability
# @trace order:797-t9m7
#
# Fixture for opencode_validate_or_rollback's three outcomes.
#
# THE DEFECT. The function announced "rolling back to last-good" BEFORE checking
# whether a last-good existed, at trace_lifecycle level — which returns early
# unless TILLANDSIAS_DEBUG is set. Measured on yoga across three cold launches
# (2026-08-17): $HARNESS_CURL_ROOT/opencode/bin stayed empty every time, the
# harness reported a rollback to a binary that had never been recorded, and in
# normal operation the whole thing was silent because the lane kept working —
# opencode resolves from the npm harness path instead.
#
# WHAT IS PINNED. Not the wording, which will drift: the DISCRIMINATION. Three
# distinct states must produce three distinct outcomes, and the empty-cache case
# must reach stderr WITHOUT TILLANDSIAS_DEBUG, because being invisible in normal
# operation is the defect.
#
# Verdict grammar:
#   ok:opencode-rollback-loud:<n> passed     exit 0
#   violation:opencode-rollback-loud:<case>  exit 1
#   blocked:<reason>                         exit 2
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

LIB="images/default/lib-common.sh"
[ -f "$LIB" ] || { echo "blocked:lib-common-missing"; exit 2; }

D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# Extract ONLY the function under test plus the two helpers it calls for paths.
# Sourcing the whole library would drag in the forge's entire environment; the
# unit under test is the branch logic, and isolating it is what lets the empty
# and populated last-good states be constructed at all.
extract() {
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
        inside { print }
        inside && /^\}/ { exit }
    ' "$LIB"
}

{
    echo 'HARNESS_CURL_ROOT="$1"'
    echo 'trace_lifecycle() { [ -n "${TILLANDSIAS_DEBUG:-}" ] || return 0; echo "[lifecycle] $1 | ${*:2}" >&2; }'
    # Stubs: the probe verdict and the restore outcome are the two inputs the
    # branch logic reads, so they are the two things the harness controls.
    echo 'harness_probe() { [ "${STUB_PROBE_OK:-0}" = "1" ]; }'
    echo 'opencode_record_curl_last_good() { :; }'
    echo 'opencode_restore_curl_last_good() { [ "${STUB_RESTORE_OK:-0}" = "1" ]; }'
    extract opencode_curl_last_good_path
    extract opencode_validate_or_rollback
    echo 'opencode_validate_or_rollback "$2"; echo "rc=$?"'
} > "$D/unit.sh"

grep -q 'opencode_validate_or_rollback()' "$D/unit.sh" || { echo "blocked:extraction-failed"; exit 2; }

run_case() { env "$@" bash "$D/unit.sh" "$D/curl" "$D/curl/opencode/bin/opencode" 2>&1; }

pass=0; fail=""

mkdir -p "$D/curl/opencode/bin" "$D/curl/opencode/last-good"

# CASE 1 — empty cache, no last-good. The state measured on yoga. Must be LOUD
# (no TILLANDSIAS_DEBUG set) and must NOT claim a rollback happened.
out="$(run_case STUB_PROBE_OK=0 STUB_RESTORE_OK=0)"
if printf '%s' "$out" | grep -q "NO last-good to roll back to"; then pass=$((pass+1)); else fail="${fail}empty-cache-not-announced "; fi
if printf '%s' "$out" | grep -qi "rolling back to last-good"; then fail="${fail}empty-cache-still-claims-rollback "; else pass=$((pass+1)); fi
printf '%s' "$out" | grep -q "rc=1" || fail="${fail}empty-cache-wrong-rc "

# CASE 2 — a last-good EXISTS and restores. The healthy rollback path must still
# work and must still be quiet at trace level (it is not a failure).
printf '#!/bin/sh\n' > "$D/curl/opencode/last-good/opencode"; chmod +x "$D/curl/opencode/last-good/opencode"
out="$(run_case STUB_PROBE_OK=0 STUB_RESTORE_OK=1)"
if printf '%s' "$out" | grep -q "rc=0"; then pass=$((pass+1)); else fail="${fail}healthy-rollback-broken "; fi
if printf '%s' "$out" | grep -q "WARNING"; then fail="${fail}healthy-rollback-warns "; else pass=$((pass+1)); fi

# CASE 3 — a last-good exists but will NOT restore. Distinct from case 1: the
# snapshot is present and unusable, which is worse, and must say so.
out="$(run_case STUB_PROBE_OK=0 STUB_RESTORE_OK=0)"
if printf '%s' "$out" | grep -q "a curl-side last-good exists"; then pass=$((pass+1)); else fail="${fail}unusable-last-good-not-distinguished "; fi

# CASE 4 — POSITIVE CONTROL. A binary that passes the probe must return 0 and
# emit no warning at all; without this every arm above is satisfied by a
# function that warns unconditionally.
printf '#!/bin/sh\n' > "$D/curl/opencode/bin/opencode"; chmod +x "$D/curl/opencode/bin/opencode"
out="$(run_case STUB_PROBE_OK=1 STUB_RESTORE_OK=0)"
if printf '%s' "$out" | grep -q "rc=0"; then pass=$((pass+1)); else fail="${fail}healthy-binary-rejected "; fi
if printf '%s' "$out" | grep -q "WARNING"; then fail="${fail}healthy-binary-warns "; else pass=$((pass+1)); fi

if [ -n "$fail" ]; then
    echo "violation:opencode-rollback-loud:${fail% }"
    exit 1
fi
echo "ok:opencode-rollback-loud:${pass} passed"

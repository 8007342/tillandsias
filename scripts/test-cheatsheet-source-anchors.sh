#!/usr/bin/env bash
# @trace order:1053-a7qr
#
# Fixture for check-cheatsheet-source-anchors.lua. The guard's whole value is
# that it refuses; a guard nobody has watched refuse is a guard nobody knows is
# wired, and the defect it was written for sat green for a month precisely
# because NOTHING read cheatsheet `sources:` anchors at all.
#
# The mention/declaration case (3) is the one that matters. The reported defect
# would have PASSED a naive "is the id in the file" check: 804-ckst appears
# nine times in plan/index.yaml as prose inside other packets. Case 3 plants
# exactly that shape and expects red.
#
# Each scenario writes ONE cheatsheet under a unique per-process name and
# removes it on every exit path. The guard walks cheatsheets/ repo-relative, so
# the fixture has to be reachable there.
#
# PORTED to Lua (1526-gv3t): the guard is
# scripts/lua/check-cheatsheet-source-anchors.lua, run through the one runner;
# no runner is a loud skip, never a silent pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

PLAN_BIN="$(. scripts/plan-binary-probe.sh 2>/dev/null && resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ] || ! grep -qx script <<<"$("$PLAN_BIN" capabilities 2>/dev/null)"; then
    echo "skip:cheatsheet-source-anchors-fixture:no-script-runner — no tillandsias-plan with \`script run\` resolves; rebuild it (cargo build --release -p tillandsias-plan)"
    exit 0
fi
CHECK="$ROOT/scripts/lua/check-cheatsheet-source-anchors.lua"

FIXTURE="cheatsheets/zz-anchor-fixture-$$.md"
cleanup() { rm -f "$ROOT/$FIXTURE"; }
trap cleanup EXIT INT TERM

pass=0
fail=0
_result() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1 — expected exit $2, got $3" >&2
    fi
}

_guard_exit() {
    "$PLAN_BIN" script run "$CHECK" >/dev/null 2>&1
    echo $?
}

_sheet() { printf 'sources:\n  - %s\nauthority: high\n\n# fixture\n' "$1" > "$FIXTURE"; }

# The tree must be green before we perturb it, or every result below is
# measuring someone else's bad anchor rather than the fixture's.
baseline="$(_guard_exit)"
if [[ "$baseline" != "0" ]]; then
    echo "SKIP: anchor guard is already failing on this tree (exit $baseline) — the fixture cannot attribute its own result" >&2
    exit 0
fi

# 1. A file that does not exist.
_sheet "openspec/specs/NOT-A-FILE.md order:9999-zzzz"
_result "nonexistent file is caught" 1 "$(_guard_exit)"

# 2. A real file that declares nothing of the sort.
_sheet "README.md order:9999-zzzz"
_result "order declared nowhere is caught" 1 "$(_guard_exit)"

# 3. THE REPORTED DEFECT. A real file where the order appears only as PROSE in
#    other packets' bodies, while its declaration lives in the archive. A
#    substring check passes this; only the declaration form catches it.
_sheet "plan/index.yaml order:804-ckst"
_result "live-ledger anchor for an archived order is caught" 1 "$(_guard_exit)"

# 4. The same order anchored at the file that DECLARES it.
_sheet "plan/archive/packets-2026-08.yaml order:804-ckst"
_result "anchor at the declaring file passes" 0 "$(_guard_exit)"

# 5. A cheatsheet with no order anchors at all is not an error.
printf 'sources:\n  - some/free/text.md\nauthority: low\n' > "$FIXTURE"
_result "sources without an order anchor are ignored" 0 "$(_guard_exit)"

rm -f "$FIXTURE"
echo "cheatsheet-source-anchor fixture: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]

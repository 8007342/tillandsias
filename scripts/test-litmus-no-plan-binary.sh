#!/usr/bin/env bash
# @trace order:1419-zydw
#
# test-litmus-no-plan-binary.sh — the litmus runner refuses ONCE, by name, when
# no RUNNABLE tillandsias-plan resolves, instead of letting plan-backed steps
# degrade into several unrelated-looking reds.
#
# MEASURED 2026-09-26 (darwin, fresh linked worktree, meta-orchestration): four
# reds with four surfaces — a lease on the fixture's fake id, missing=2, "no
# runnable tillandsias-plan", a failed methodology query — all green once a
# binary was supplied. And a broken TILLANDSIAS_PLAN_BIN made the runner exit
# with the stub's own rc and NO output (`set -e` on the capabilities probe).
#
# Fast by construction: every arm names a spec that matches nothing, so the
# refusal (which happens before selection) is all that is measured, and the
# admitted arms stop at the runner's own "no litmus tests matched".
#
# Grammar: `ok:litmus-no-plan-binary:<n> arms` (rc 0) or
#          `FAIL:litmus-no-plan-binary:<n> failed` (rc 1).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-litmus-test.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/litmus-no-plan-bin.XXXXXX")"
trap 'rm -rf "$T"' EXIT
SPEC="no-such-spec-1419"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# run <env assignments...> -> "<rc>|<first non-warn stdout line>"
run() {
    local out rc
    out="$(cd "$ROOT" && env "$@" bash "$RUNNER" "$SPEC" --phase pre-build --size instant --compact 2>/dev/null)"
    rc=$?
    printf '%s|%s\n' "$rc" "$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -v '^warn:' | grep -m1 . || true)"
}

# 1. No binary at all: an override naming a path that does not exist resolves
#    nothing (resolve_plan_binary honours an override on existence).
r="$(run TILLANDSIAS_PLAN_BIN="$T/absent" CARGO_TARGET_DIR="$T/no-target")"
[ "$r" = "2|blocked:litmus-no-plan-binary" ] \
    && ok "no plan binary -> one named refusal, rc 2" \
    || bad "no plan binary: expected '2|blocked:litmus-no-plan-binary', got '$r'"

# 2. A binary that EXISTS but does not run is refused too, by its own name —
#    before 1419-zydw it ended the runner silently with the stub's rc.
printf '#!/bin/sh\nexit 3\n' > "$T/broken"; chmod +x "$T/broken"
r="$(run TILLANDSIAS_PLAN_BIN="$T/broken")"
[ "$r" = "2|blocked:litmus-plan-binary-unrunnable:$T/broken" ] \
    && ok "unrunnable binary -> named refusal, not a silent exit" \
    || bad "unrunnable binary: got '$r'"

# 3. The opt-out restores the pre-1419 behaviour: the run proceeds.
r="$(run TILLANDSIAS_PLAN_BIN="$T/absent" CARGO_TARGET_DIR="$T/no-target" TILLANDSIAS_LITMUS_ALLOW_NO_PLAN_BIN=1)"
case "$r" in
    (*blocked:litmus-*) bad "opt-out still refused: '$r'" ;;
    (*) ok "TILLANDSIAS_LITMUS_ALLOW_NO_PLAN_BIN=1 proceeds past the check" ;;
esac

# 4. A runnable binary is admitted untouched (skipped, named, if this host has
#    none — the arm cannot be judged without one).
. "$ROOT/scripts/plan-binary-probe.sh" 2>/dev/null || true
real="$(resolve_plan_binary 2>/dev/null || true)"
if [ -n "$real" ] && "$real" capabilities >/dev/null 2>&1; then
    r="$(run TILLANDSIAS_PLAN_BIN="$real")"
    case "$r" in
        (*blocked:litmus-*) bad "a runnable binary was refused: '$r'" ;;
        (*) ok "a runnable binary is admitted" ;;
    esac
else
    echo "skip runnable-binary-admitted (no runnable tillandsias-plan on this host)"
fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL:litmus-no-plan-binary:$fail failed"
    exit 1
fi
echo "ok:litmus-no-plan-binary:$pass arms"
exit 0

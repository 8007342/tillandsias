#!/usr/bin/env bash
# @trace order:1302-7j8p, spec:ci-release
#
# Fixture for scripts/check-gate-step-regimes.sh. Hermetic: every arm builds a
# throwaway step directory and never reads the live scripts/gate-steps.d, so the
# fixture cannot go red because the fleet is mid-backfill, and cannot go green
# because the fleet happens to be finished.
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || { echo 'FAIL: run under bash'; exit 2; }
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-gate-step-regimes.sh"
[ -x "$CHECK" ] || { echo "skip:gate-step-regimes-fixture:checker-absent"; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/gate-step-regimes.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT INT TERM
rc=0
pass=0
fail() { printf 'FAIL:%s\n' "$*" >&2; rc=1; }

mk() { # $1=dir $2=file $3=optional STEP_SECOND_REGIME value
    mkdir -p "$1"
    {
        printf 'STEP_DESC="probe"\n'
        printf 'STEP_SCRIPT="scripts/true.sh"\n'
        printf 'STEP_ERROR="probe failed"\n'
        printf 'STEP_OK="probe ok"\n'
        [ "$#" -ge 3 ] && printf 'STEP_SECOND_REGIME="%s"\n' "$3"
    } > "$1/$2"
}

# ── ARM 1 — a step with NO record is NAMED, not merely counted ───────────────
d="$tmp/a1"; mk "$d" "100-probe.step"
out="$(bash "$CHECK" "$d" 2>&1)"; arc=$?
if [ "$arc" -eq 0 ]; then
    fail "arm1:a step with no second-regime record must not pass (rc=0)"
elif ! grep -q 'violation:gate-step-single-regime:100-probe.step' <<<"$out"; then
    fail "arm1:the violation must NAME the step; got: $out"
else
    pass=$((pass + 1)); echo "ok:gate-step-regimes-fixture:arm1-unrecorded-step-is-named"
fi

# ── ARM 2 — a step WITH a record passes ─────────────────────────────────────
d="$tmp/a2"; mk "$d" "100-probe.step" "macneo 2026-09-22 darwin ok:probe-passed"
out="$(bash "$CHECK" "$d" 2>&1)"; arc=$?
if [ "$arc" -ne 0 ]; then
    fail "arm2:a step carrying a darwin record must pass (rc=$arc); got: $out"
elif ! grep -q '^ok:gate-step-regimes:1$' <<<"$out"; then
    fail "arm2:expected ok:gate-step-regimes:1; got: $out"
else
    pass=$((pass + 1)); echo "ok:gate-step-regimes-fixture:arm2-recorded-step-passes"
fi

# ── ARM 3 — a record naming only LINUX is still single-regime ───────────────
# THE ARM THAT MATTERS. Arms 1 and 2 are satisfied by a checker that merely
# asks whether the variable EXISTS. This one requires it to read the regime:
# a Linux host writing its own run into the field must not satisfy a check
# whose entire purpose is evidence from the OTHER regime.
d="$tmp/a3"; mk "$d" "100-probe.step" "lenovinha 2026-09-22 linux ok:probe-passed"
out="$(bash "$CHECK" "$d" 2>&1)"; arc=$?
if [ "$arc" -eq 0 ]; then
    fail "arm3:a linux-only record must NOT satisfy the second-regime check (rc=0)"
elif ! grep -q 'is-not-a-second-regime' <<<"$out"; then
    fail "arm3:the refusal must say WHY the regime does not count; got: $out"
else
    pass=$((pass + 1)); echo "ok:gate-step-regimes-fixture:arm3-linux-only-is-single-regime"
fi

# ── ARM 4 (CONTROL) — a NAMED SKIP counts as a record ───────────────────────
# Not one of the three the row names, and load-bearing anyway: without it a
# checker could satisfy arms 1-3 while refusing steps that legitimately cannot
# run off Linux, which would make the backfill impossible to finish honestly
# and push people toward inventing green verdicts (965-sxec).
d="$tmp/a4"; mk "$d" "100-probe.step" "macneo 2026-09-22 darwin skip:no-podman-on-darwin"
out="$(bash "$CHECK" "$d" 2>&1)"; arc=$?
if [ "$arc" -ne 0 ]; then
    fail "arm4:a NAMED SKIP from the other regime must count as a record (rc=$arc); got: $out"
else
    pass=$((pass + 1)); echo "ok:gate-step-regimes-fixture:arm4-named-skip-counts"
fi

[ "$rc" -eq 0 ] && echo "ok:gate-step-regimes-fixture:$pass/4" || echo "violation:gate-step-regimes-fixture"
exit $rc

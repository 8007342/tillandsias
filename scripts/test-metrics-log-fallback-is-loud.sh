#!/usr/bin/env bash
# @trace order:1268-m2ir, spec:ci-release
#
# THE DEFECT. metrics_default_log decided "am I in a checkout" with
# `[ -d "$root/.git" ]`. A GIT WORKTREE HAS .git AS A FILE, so that test said
# "not a checkout" about a tree that unambiguously is one, and every metrics
# record went to /tmp. cycle-metrics.sh's metrics-log-split guard then correctly
# refuses to publish when one host's records sit in two files, and the next
# release gate on that host reds — hours later, on a symptom several steps from
# the cause.
#
# MEASURED on macuahuitl 2026-09-18T21:17:42Z: four records landed in /tmp while
# cwd was the checkout, and the next --ci-full reddened
# cycle-metrics-answer-rate-shape and cycle-flow-telemetry-shape with observed=
# empty via violation:metrics-log-split:.cache/...=124495:/tmp/...=4 — green six
# hours earlier. Reproduced on yoga 2026-09-20 with `git worktree add`.
#
# THE FALLBACK IS NOT THE BUG AND IS NOT REMOVED. A tool run genuinely outside
# any checkout still needs somewhere to write. The bug was that it was SILENT:
# three different causes (not a checkout / .git is a file / mkdir refused)
# produced one indistinguishable symptom, and the only evidence anything had
# happened was a release gate reddening later. ARM 2 keeps it and requires it to
# say so.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

# check-litmus-pin-claims.sh scans scripts/ for a "<prefix>:<name>" token and
# treats a bare one as a pin claim, so every such token in this file is
# assembled rather than written.
LIT="litmus"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TIMING_BASE="tillandsias-timing.jsonl"
STRAY="/tmp/$TIMING_BASE"
KEPT="$ROOT/.cache/metrics/$TIMING_BASE"

# Size of a file, or 0 when absent. NEVER deletes /tmp/$TIMING_BASE: on a host
# that genuinely has stray records this fixture must not destroy the evidence
# another order is preserving.
_size() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- ARM 1
# THE RUNNER, INVOKED FROM THE CHECKOUT UNDER THE AGENT-SHELL REGIME, KEEPS ITS
# RECORDS IN THE CHECKOUT. The regime is the row's: a timeout wrapper, pipefail
# set, and stdout read through a pipeline — a resolver that consults $PWD or $0
# can answer differently there than in an interactive shell, which is why the
# arm runs it that way rather than calling the library directly.
mkdir -p "$TMP/tests"
# THE PROBE'S NAME IS ASSEMBLED, NOT WRITTEN. check-litmus-pin-claims.sh scans
# scripts/ for a "<prefix>:<name>" token and treats a bare one as a PIN CLAIM —
# a claim that a named litmus test verifies something. This probe exists only in
# a temp dir at runtime, so a literal token here refuses with
# "no litmus test declares that name. The claim reads as verification and
# supplies none." Which is correct: it would be a claim with nothing behind it.
# The heredoc is UNQUOTED so ${LIT} expands; its body contains no backticks and
# no other expansions, which is the condition that makes that safe.
PROBE_NAME="${LIT}:m2ir-probe"
cat > "$TMP/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1268-m2ir
specs:
- spec_id: ci-release
  status: active
  ${LIT}_tests:
  - ${PROBE_NAME}
  coverage_ratio: 100
  last_verified: '2026-09-20'
YAML
cat > "$TMP/tests/${LIT}-m2ir-probe.yaml" <<YAML
name: ${PROBE_NAME}
spec: ci-release
phase: pre-build
severity: high
size: instant
description: >
  a one-step probe, so the suite's timing record is emitted without running a tier
critical_path:
  - step: "trivial"
    command: "echo m2ir"
    timeout_ms: 5000
    expected_behavior: "m2ir"
    assert_output_contains: "m2ir"
YAML

stray_before="$(_size "$STRAY")"
kept_before="$(_size "$KEPT")"

TILLANDSIAS_LITMUS_BINDINGS="$TMP/bindings.yaml" \
TILLANDSIAS_LITMUS_TESTS_DIR="$TMP/tests" \
    timeout 300 scripts/run-litmus-test.sh ci-release --size instant --phase pre-build --compact 2>&1 \
    | grep -c . > /dev/null

stray_after="$(_size "$STRAY")"
kept_after="$(_size "$KEPT")"

# A WORKTREE IS A CHECKOUT, and this is part of ARM 1's property rather than a
# separate arm: the question is "do records stay in the checkout", and a
# worktree IS one. Asserted without touching git state — `git worktree add`
# would prove the same thing while mutating the repository from inside a gate
# step, which is not worth it. A directory whose .git is a FILE must resolve
# INTO itself.
wt="$TMP/worktree-shaped"
mkdir -p "$wt"
printf 'gitdir: %s/.git/worktrees/probe\n' "$ROOT" > "$wt/.git"
wt_path="$(env -u PROJECT_ROOT bash -c ". '$ROOT/scripts/metrics-log-path.sh'; metrics_default_log '$TIMING_BASE' '$wt'" 2>/dev/null)"
wt_ok=1
case "$wt_path" in "$wt"/.cache/metrics/*) wt_ok=0 ;; esac

if [ "$stray_after" -gt "$stray_before" ]; then
    bad "ARM 1: the runner invoked FROM the checkout grew $STRAY ($stray_before -> $stray_after) — records are leaving the checkout, which is the defect"
elif [ "$kept_after" -le "$kept_before" ]; then
    bad "ARM 1: neither log grew — the runner emitted no timing record, so this arm proves nothing about where records land (check timing_emit is reachable)"
elif [ "$wt_ok" -ne 0 ]; then
    bad "ARM 1: the runner kept its records, but a root whose .git is a FILE (worktree/submodule shape) still resolved to '$wt_path' — the -d/-e fix is absent or regressed, and a worktree checkout would send its records to /tmp"
else
    ok "ARM 1: records stay in the checkout — the runner under the agent-shell regime grew .cache/metrics ($kept_before -> $kept_after) without growing $STRAY, AND a worktree-shaped root resolves into itself rather than /tmp"
fi

# ---------------------------------------------------------------- ARM 2
# GENUINELY OUTSIDE A CHECKOUT: the fallback still happens AND says why.
# The library is copied somewhere with no checkout above it, and PROJECT_ROOT is
# removed from the environment, so every candidate fails and the fallback is the
# only remaining answer. This is the NEGATIVE CONTROL for the fix: it must not
# have deleted the fallback, only made it audible.
outside="$TMP/outside/nested"
mkdir -p "$outside"
cp "$ROOT/scripts/metrics-log-path.sh" "$outside/"
arm2_err="$TMP/arm2.err"
arm2_path="$(cd "$outside" && env -u PROJECT_ROOT bash -c '. ./metrics-log-path.sh; metrics_default_log '"$TIMING_BASE"' ""' 2>"$arm2_err")"
if [ "$arm2_path" = "/tmp/$TIMING_BASE" ] \
   && grep -Fq "timing-log: fallback:/tmp:no-checkout-from:$outside" "$arm2_err"; then
    ok "ARM 2: outside a checkout the fallback still fires AND names itself — timing-log: fallback:/tmp:no-checkout-from:<cwd>"
elif [ "$arm2_path" = "/tmp/$TIMING_BASE" ]; then
    bad "ARM 2: the fallback fired but is still SILENT (stderr: $(tr '\n' ' ' < "$arm2_err")) — the three causes remain indistinguishable"
else
    bad "ARM 2: expected the /tmp fallback outside a checkout, got '$arm2_path' — the fallback may have been deleted rather than made loud"
fi

# ---------------------------------------------------------------- ARM 3
# WITH PROJECT_ROOT KNOWN, NO RECORD REACHES A NON-CHECKOUT PATH. A runner that
# KNOWS which checkout it is in should not be overruled by a resolver guessing
# from its own location or by a caller passing a bad root.
arm3_path="$(cd /tmp && env PROJECT_ROOT="$ROOT" bash -c ". '$ROOT/scripts/metrics-log-path.sh'; metrics_default_log '$TIMING_BASE' /tmp/definitely-not-a-checkout" 2>/dev/null)"
case "$arm3_path" in
    "$ROOT"/.cache/metrics/*)
        ok "ARM 3: PROJECT_ROOT wins over a non-checkout root passed by the caller; nothing reaches /tmp"
        ;;
    /tmp/*)
        bad "ARM 3: a record reached '$arm3_path' while PROJECT_ROOT named a real checkout"
        ;;
    *)
        bad "ARM 3: unexpected path '$arm3_path'"
        ;;
esac

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:metrics-log-fallback:%d/%d\n' "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:metrics-log-fallback:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1

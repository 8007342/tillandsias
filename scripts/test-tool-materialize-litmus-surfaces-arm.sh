#!/usr/bin/env bash
# @trace order:1269-gfdi, spec:ci-release
#
# THE DEFECT. litmus:tool-materialization's arms step ended in `| tail -1`, so a
# red printed exactly one line — `tool-materialize: FAIL` — which names no arm,
# no measurement and no regime. Every `FAIL: ARM <n>: …` the fixture writes was
# discarded. Inside a 900s release-tier step that discarded line is the only
# thing a reader will ever get.
#
# MEASURED on macuahuitl 2026-09-19T05:15Z at 720e148bc: the step's captured
# output was that single line, while the same fixture standalone in the same
# toolbox seconds later printed `ok:tool-materialize:all` with the margin arm at
# 1929ms vs 20473ms. The arm that reds under load has no regime line, and the
# `tail -1` threw away whichever arm it was — so the two candidate causes (a
# loaded host, or /tmp hitting its usrquota during extraction) could not be told
# apart from the evidence that survived.
#
# WHAT THIS PINS. Not "the fixture passes" — it already did, standalone. That a
# RED IS READABLE, and that a ratio measured in a bad regime reports a named
# skip instead of a bare red.
#
# HOW THE ARMS DRIVE IT, and why this is not testing a stub: the fixture honours
# TILLANDSIAS_TOOL_MATERIALIZE_FORCE_MARGIN_FAIL, which fails the MEASUREMENT
# only, and TILLANDSIAS_TOOL_MATERIALIZE_LOADAVG / _AVAIL_KB, which inject the
# probe's INPUTS. The branch that chooses skip-vs-red is the same branch
# production runs; nothing here overrides the verdict itself. ARM 0 additionally
# requires the probe to read the REAL host values with nothing injected, so the
# production reading path is exercised and not merely bypassed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0; skipped=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }
# ORDER 1300-q7eq. A NAMED SKIP IS NOT A PASS AND IS NOT A FAILURE. It counts
# separately so the verdict can never imply an arm ran when it could not.
skiparm() { printf 'skip: %s\n' "$1"; skipped=$((skipped + 1)); }
# Set by ARM 0 when the subject skipped its toolbox-dependent arms.
NO_TOOLBOX=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SUBJECT="scripts/test-tool-materialize.sh"
LIT="litmus"
STEP_FILE="openspec/${LIT}-tests/${LIT}-tool-materialization.yaml"

# ---------------------------------------------------------------- ARM 0
# THE PRODUCTION READING PATH RUNS. With nothing injected the probe must report
# a real load figure and a real free-space figure for this host. Without this,
# arms 1 and 2 would both pass against injected inputs while the code that reads
# /proc/loadavg and df could be broken or absent.
if ! bash "$SUBJECT" > "$TMP/real.out" 2>&1; then
    bad "ARM 0: the subject fixture is RED on this host with nothing injected — every arm below would be measuring a broken baseline; see $TMP/real.out"
elif grep -q 'skip: arms 4-7 need a toolbox on this host' "$TMP/real.out"; then
    # ORDER 1300-q7eq. THE MARGIN ARM IS ARM 7, AND ARMS 4-7 NEED A TOOLBOX.
    # macOS and Windows hosts have no toolbox and the subject fixture SKIPS them
    # by design — its own comment says they "legitimately have neither; they SKIP
    # rather than fail". So on those hosts the regime line can NEVER be printed,
    # whatever the probe reads, and requiring it made ARM 0 demand a measurement
    # the platform cannot produce. That is what red both macOS gates: not a
    # broken probe, but an arm asserting a precondition it never checked.
    # A check that could not run must not claim what it would have found
    # (965-sxec). Accept the subject's own named skip and say what is untested.
    NO_TOOLBOX=1
    ok "ARM 0: no toolbox on this host, so the subject SKIPPED arms 4-7 by design and the regime probe could not run — arms 1, 1b and 2 are skipped by name below for the same reason, so NOTHING in this run exercises the margin arm; that coverage lives on a host with a toolbox"
elif grep -q 'skip:tool-materialize-margin:no-regime-probe' "$TMP/real.out"; then
    # ORDER 1300-q7eq. A host with NO readable probe source — no /proc/loadavg
    # and no sysctl vm.loadavg — cannot print a measured regime, and demanding
    # one from it would red this arm forever on that platform while asserting
    # nothing about the mechanism. The subject fixture names that absence rather
    # than guessing, and the named token IS the production reading path being
    # exercised: it proves the probe ran and reported what it could not read.
    # This is NOT a way to pass without measuring — the token only appears when
    # every source was tried and failed.
    ok "ARM 0: the host has no readable regime probe source and the margin arm NAMED that absence (skip:tool-materialize-margin:no-regime-probe) rather than redding"
elif grep -qE 'regime quiet \(load [0-9]+\.[0-9]+ on [0-9]+ cpus, [0-9]+kB free\)' "$TMP/real.out"; then
    ok "ARM 0: the regime probe read REAL host values with nothing injected ($(grep -oE 'load [0-9.]+ on [0-9]+ cpus, [0-9]+kB free' "$TMP/real.out" | head -1))"
else
    bad "ARM 0: the margin arm did not report a measured regime from the real host — the probe's production reading path is not exercised by arms 1-2, which inject their inputs"
fi

# ORDER 1300-q7eq. ARMS 1, 1b AND 2 ALL INJECT INTO THE MARGIN ARM, WHICH IS
# ARM 7 OF THE SUBJECT — and arms 4-7 need a toolbox. On a host without one the
# subject skips them by design, so the injected inputs never reach the code
# under test and these arms would red while asserting NOTHING about it. That is
# what red both macOS gates. Skip them BY NAME instead, and let the verdict say
# how many were skipped, so a green here can never be read as coverage that did
# not happen (965-sxec: a check that could not run must not claim what it would
# have found).
if [ "$NO_TOOLBOX" -eq 1 ]; then
    skiparm "ARM 1: needs a toolbox — the subject skips its margin arm on this host, so a forced failure never reaches it"
    skiparm "ARM 1b: needs a toolbox — same reason as ARM 1"
    skiparm "ARM 2: needs a toolbox — an injected load cannot reach a margin arm that does not run"
else
# ---------------------------------------------------------------- ARM 1
# A RED NAMES ITS ARM, AND THE VERDICT SURVIVES TOO. Driven through the REAL
# litmus step, because the `tail -1` lived in the step's command and not in the
# fixture — running the fixture directly would have been green all along and is
# exactly the check that missed this for as long as it existed.
#
# The regime is forced QUIET so the guard does not (correctly) convert this into
# a skip: this arm is about a genuine red being legible.
# SCOPED TO THIS ONE TEST via the runner's discovery seams. The first version
# ran the whole ci-release suite: slow, and worse, an unrelated red anywhere in
# that suite would have been indistinguishable from this arm's forced one.
mkdir -p "$TMP/tests"
cp "$STEP_FILE" "$TMP/tests/"
cat > "$TMP/bindings.yaml" <<YAML
version: '1.0'
description: fixture for 1269-gfdi
specs:
- spec_id: ci-release
  status: active
  ${LIT}_tests:
  - ${LIT}:tool-materialization
  coverage_ratio: 100
  last_verified: '2026-09-20'
YAML

step_out="$TMP/arm1.out"
TILLANDSIAS_TOOL_MATERIALIZE_FORCE_MARGIN_FAIL=1 \
TILLANDSIAS_TOOL_MATERIALIZE_LOADAVG=0.01 \
TILLANDSIAS_TOOL_MATERIALIZE_AVAIL_KB=99999999 \
TILLANDSIAS_LITMUS_BINDINGS="$TMP/bindings.yaml" \
TILLANDSIAS_LITMUS_TESTS_DIR="$TMP/tests" \
    scripts/run-${LIT}-test.sh ci-release --phase pre-build --size instant --compact \
    > "$step_out" 2>&1
step_rc=$?

if [ "$step_rc" -eq 0 ]; then
    bad "ARM 1: the litmus step PASSED while an arm was forced to fail — the step is not adjudicating on the fixture's verdict at all"
elif grep -Fq 'ARM 7' "$step_out" && grep -Fq 'tool-materialize: FAIL' "$step_out"; then
    ok "ARM 1: the red NAMES the failing arm and keeps the summary verdict (pre-fix: only 'tool-materialize: FAIL' survived the tail)"
elif grep -Fq 'tool-materialize: FAIL' "$step_out"; then
    bad "ARM 1: the captured output has the summary verdict but NOT the failing arm — this is the pre-fix behaviour, the reason is still being discarded"
else
    bad "ARM 1: the captured output names neither the arm nor the verdict; see $step_out"
fi

# ALSO REQUIRE THE MEASUREMENT ITSELF, since "names the arm" is satisfiable by a
# bare label. A reader needs the numbers to tell a broken mechanism from a slow
# host, and those numbers are what the regime line exists to contextualise.
if grep -qE 'bought less than 4x over per-call dispatch \([0-9]+ms vs [0-9]+ms' "$step_out"; then
    ok "ARM 1b: the red carries its measurement and states the regime probe found the host quiet, so load is excluded in the output itself"
else
    bad "ARM 1b: the red names an arm but not its numbers — a reader still cannot tell a broken mechanism from a slow host"
fi

# ---------------------------------------------------------------- ARM 2
# UNDER A BAD REGIME: A NAMED SKIP WITH ITS NUMBERS, NEVER A BARE RED. Same
# forced measurement failure as ARM 1; only the injected regime differs, so this
# arm isolates the guard rather than the measurement.
skip_out="$TMP/arm2.out"
TILLANDSIAS_TOOL_MATERIALIZE_FORCE_MARGIN_FAIL=1 \
TILLANDSIAS_TOOL_MATERIALIZE_LOADAVG=99.0 \
    bash "$SUBJECT" > "$skip_out" 2>&1
skip_rc=$?

if [ "$skip_rc" -ne 0 ]; then
    bad "ARM 2: a ratio that failed under a loaded host produced a RED (rc=$skip_rc) — the regime guard did not fire; see $skip_out"
elif grep -qE 'skip:tool-materialize-margin:loaded-host:load=99\.0:cpus=[0-9]+ \([0-9]+ms vs [0-9]+ms' "$skip_out" \
     && grep -Fq 'ok:tool-materialize:all' "$skip_out"; then
    ok "ARM 2: a loaded host yields skip:tool-materialize-margin:<regime> WITH its numbers, and the run still ends in its verdict token"
elif grep -Fq 'skip:tool-materialize-margin' "$skip_out"; then
    bad "ARM 2: the skip is named but is missing its regime detail or its measurements, or the verdict token did not survive it"
else
    bad "ARM 2: no named skip under a loaded host; see $skip_out"
fi

fi
# ---------------------------------------------------------------- ARM 3
# THE STEP NO LONGER TRUNCATES. A regression guard on the literal idiom, because
# the defect was one pipeline element and would return unnoticed: the next
# author trimming noisy output reaches for exactly this.
# THE CHECK IS ON THE `command:` LINES ONLY, NOT THE WHOLE FILE, and that is the
# point rather than a convenience. The first version of this arm grepped the
# file and FAILED — because the comment added above the step EXPLAINS the
# removed pipeline and therefore contains the literal it searches for. The
# documentation answered the grep. A matcher run over a set that includes its
# own description reports itself; the property being pinned is that the step's
# COMMAND does not truncate, which leaves the history free to be written down.
if grep -E '^[[:space:]]*command:' "$STEP_FILE" | grep -Fq 'tail -1'; then
    bad "ARM 3: a step's command pipes through 'tail -1' again — a red will print one contentless line"
else
    ok "ARM 3: no step command in $STEP_FILE truncates its output (the comment above the step may name the idiom; commands may not use it)"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    # ORDER 1300-q7eq. THE SKIP COUNT TRAVELS WITH THE VERDICT. Printing
    # `N/N` while arms were skipped would state a coverage this run did not have,
    # and the next reader would take a green here as "the margin arm is
    # exercised on this host" when nothing exercised it. Name the absence.
    if [ "$skipped" -gt 0 ]; then
        printf 'ok:tool-materialize-%s:arm-surfaced:%d/%d (%d skipped: no toolbox on this host, margin arm not exercised here)\n' \
            "$LIT" "$pass" "$((pass + fail))" "$skipped"
        exit 0
    fi
    printf 'ok:tool-materialize-%s:arm-surfaced:%d/%d\n' "$LIT" "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:tool-materialize-%s:arm-surfaced:%d-failed-of-%d\n' "$LIT" "$fail" "$((pass + fail))"
exit 1

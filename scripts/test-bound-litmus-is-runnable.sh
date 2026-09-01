#!/usr/bin/env bash
# @trace spec:ci-release, spec:methodology-accountability
# @trace order:958-b36m, order:660-ryhn, order:944-vim8
#
# Fixture for the bound-but-unrunnable check.
#
# THE DEFECT, caused by the author of this fixture. litmus:codex-e2e-launch-parity
# landed 2026-09-01 keyed `steps:` where run-litmus-test.sh reads
# `critical_path:`. It extracted ZERO steps, failed whole, and reddened every
# full pre-build litmus run fleet-wide for ~4h. It had passed THREE gates on the
# way in: valid YAML (933-4gm8), correctly bound (660-ryhn), behaviour-asserting
# steps (634-39ik). Three green checks over a file no runner could enter.
#
# The class is 944-vim8 one file format over, with the same key name: content
# keyed where the READER does not look, which parses and validates and reads
# correctly to a human and is silently ignored.
#
# WHAT IS PINNED: that the check ASKS THE RUNNER. A reimplemented parser would
# assert this script's idea of the format and could pass a file the runner
# refuses — strictly worse than no check.
#
# Verdict grammar:
#   ok:bound-litmus-runnable:<n> passed     exit 0
#   violation:bound-litmus-runnable:<case>  exit 1
#   blocked:<reason>                        exit 2
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

RUNNER="scripts/run-litmus-test.sh"
[ -x "$RUNNER" ] || { echo "blocked:no-runner"; exit 2; }

D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT

# The synthetic names are ASSEMBLED rather than spelled, so this file contains
# no literal pin token. check-litmus-pin-claims.sh (721-77yu) scans scripts for
# claimed pins and refuses names no test declares — correctly, since a claim
# that reads as verification and supplies none is worse than silence. Its own
# header takes the same precaution for the same reason.
LP="litmus"
GOOD_NAME="${LP}:fixture-good"
BAD_NAME="${LP}:fixture-bad"
pass=0; fail=""

good="$D/litmus-fixture-good.yaml"
bad="$D/litmus-fixture-bad.yaml"
cat > "$good" <<GOODEOF
name: $GOOD_NAME
spec: ci-release
phase: pre-build
description: fixture
severity: low
size: instant
critical_path:
  - step: "a step the runner can extract"
    command: "echo 'ok: fixture'"
    timeout_ms: 1000
    expected_behavior: "ok: fixture"
GOODEOF
# The EXACT defect: the block keyed where the runner does not look.
sed 's/^critical_path:$/steps:/' "$good" > "$bad"

# 1. The runner accepts an extractable file and reports its step count.
out="$("$RUNNER" --parse-only "$good" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ok:litmus-parseable:.*1 step'; then
    pass=$((pass + 1))
else
    fail="${fail}good-file-not-accepted(rc=$rc) "
fi

# 2. NEGATIVE: the runner refuses the mis-keyed file. Without this the mode is
#    satisfied by one that accepts everything.
out="$("$RUNNER" --parse-only "$bad" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'no parseable critical_path steps'; then
    pass=$((pass + 1))
else
    fail="${fail}bad-file-not-refused(rc=$rc) "
fi

# 3. PARSE-ONLY EXECUTES NOTHING. The whole point is asking without running; a
#    mode that ran the steps would be a test run wearing a check's name.
marker="$D/executed"
cat > "$D/litmus-fixture-side-effect.yaml" <<SIDEEOF
name: ${LP}:fixture-side-effect
spec: ci-release
phase: pre-build
description: fixture
severity: low
size: instant
critical_path:
  - step: "would touch a marker if executed"
    command: "touch $marker; echo 'ok: ran'"
    timeout_ms: 1000
    expected_behavior: "ok: ran"
SIDEEOF
"$RUNNER" --parse-only "$D/litmus-fixture-side-effect.yaml" >/dev/null 2>&1
if [ -e "$marker" ]; then
    fail="${fail}parse-only-executed-a-step "
else
    pass=$((pass + 1))
fi

# 4. A missing file is its own named state, not a silent pass.
out="$("$RUNNER" --parse-only "$D/definitely-absent.yaml" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'blocked:parse-only:missing'; then
    pass=$((pass + 1))
else
    fail="${fail}missing-file-not-named(rc=$rc) "
fi

# 5. Naming no file at all refuses rather than passing vacuously — a check
#    invoked with an empty list must not report success over nothing.
out="$("$RUNNER" --parse-only 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'blocked:parse-only:no files named'; then
    pass=$((pass + 1))
else
    fail="${fail}empty-invocation-not-refused(rc=$rc) "
fi

# 6. THE GATE ITSELF refuses a newly-bound unrunnable file. Built as a throwaway
#    git repo so the diff-scoping is exercised for real rather than assumed.
g="$D/repo"
mkdir -p "$g/openspec/litmus-tests" "$g/scripts"
cp scripts/check-litmus-bindings.sh "$g/scripts/"
cp scripts/run-litmus-test.sh "$g/scripts/" 2>/dev/null || true
cp -r scripts/lib "$g/scripts/lib" 2>/dev/null || true
printf 'version: "1.0"\nspecs:\n- spec_id: ci-release\n  status: active\n  litmus_tests: []\n' > "$g/openspec/litmus-bindings.yaml"
: > "$g/openspec/litmus-tests/unbound-grandfathered.txt"
git -C "$g" init -q 2>/dev/null
git -C "$g" add -A >/dev/null 2>&1
git -C "$g" -c user.email=f@f -c user.name=f commit -qm base >/dev/null 2>&1
git -C "$g" branch -f base-ref >/dev/null 2>&1
# Now ADD a bound-but-unrunnable file, exactly the 2026-09-01 shape.
cp "$bad" "$g/openspec/litmus-tests/litmus-fixture-bad.yaml"
sed -i "s|name: $GOOD_NAME|name: $BAD_NAME|" "$g/openspec/litmus-tests/litmus-fixture-bad.yaml"
sed -i "s|  litmus_tests: \[\]|  litmus_tests:\n  - $BAD_NAME|" "$g/openspec/litmus-bindings.yaml"
out="$(cd "$g" && LITMUS_BINDINGS_ROOT="$g" TILLANDSIAS_LITMUS_BIND_BASE=base-ref bash scripts/check-litmus-bindings.sh 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'violation:bound-but-unrunnable'; then
    pass=$((pass + 1))
else
    fail="${fail}gate-did-not-refuse-newly-bound-unrunnable(rc=$rc:$out) "
fi

# 7. POSITIVE CONTROL for the gate: the same shape with an EXTRACTABLE file
#    must pass. Without this, arm 6 is satisfied by a gate that refuses every
#    newly-bound file, which would block all future litmus work.
cp "$good" "$g/openspec/litmus-tests/litmus-fixture-bad.yaml"
sed -i "s|name: $GOOD_NAME|name: $BAD_NAME|" "$g/openspec/litmus-tests/litmus-fixture-bad.yaml"
out="$(cd "$g" && LITMUS_BINDINGS_ROOT="$g" TILLANDSIAS_LITMUS_BIND_BASE=base-ref bash scripts/check-litmus-bindings.sh 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
else
    fail="${fail}gate-refused-a-runnable-newly-bound-file(rc=$rc:$out) "
fi

if [ -n "$fail" ]; then
    echo "violation:bound-litmus-runnable:${fail% }"
    exit 1
fi
echo "ok:bound-litmus-runnable:${pass} passed"

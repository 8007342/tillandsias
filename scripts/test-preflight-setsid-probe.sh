#!/usr/bin/env bash
# @trace spec:build-script-architecture
#
# test-preflight-setsid-probe.sh — order 1352-vmbc.
#
# WHAT IT PROTECTS. `./build.sh --preflight` runs every guard that can refuse a
# push, and it ran each one under `setsid` unconditionally. `setsid` is
# util-linux. MEASURED on macOS before the fix:
#
#     ./build.sh: line 316: exec: setsid: not found
#     refused:preflight:ran=0 skipped=3 failed=108 wall=26s
#
# ran=0 — none of the 108 launched, and 108 identical launch failures are
# indistinguishable from 108 real refusals to anyone reading the summary. After:
#
#     refused:preflight:ran=94 skipped=16 failed=1 isolation=none-no-setsid
#
# WHY SOURCE SHAPE AND NOT A LIVE RUN. The live run is 150s, which is the one
# thing a front-door step cannot be. The behavioural evidence is the before/after
# pair above, recorded on the row from this host; what this fixture pins is that
# the three pieces which produce it cannot be removed silently.
#
# THE PROBE IS NOT THE POINT — THE VERDICT IS. A run without setsid keeps every
# deadline and the 124 convention and loses only process-GROUP signalling, so a
# guard leaving background children can outlive its deadline. That is a real
# difference in what the run proved, which is why arm 3 requires the summary to
# NAME the mode. A degraded run that reads like an isolated one is worse than a
# refusal.
#
# GRAMMAR — one line:
#   ^(ok:preflight-setsid-probe:[0-9]+|violation:preflight-setsid-probe:.*)$
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/build.sh" ] && [ -d "$ROOT/crates" ] || {
    echo "refused:preflight-setsid-probe:root-is-not-a-tillandsias-checkout-$ROOT"
    exit 1
}
B="$ROOT/build.sh"
ARMS=0

# Arm 1: the guard runner ASKS whether setsid exists, and caches the answer.
#
# KEYED ON THE ASSIGNMENT THE PROBE PRODUCES, not on `command -v setsid`. The
# first draft used that looser needle and DID NOT RED when the probe was
# deleted, because the summary line added by this same order also contains
# `command -v setsid` — the arm matched the wrong occurrence and could not have
# failed for the right reason.
grep -q '_PF_SETSID=setsid; else _PF_SETSID=""' "$B" || {
    echo "violation:preflight-setsid-probe:guard-runner-does-not-probe-for-setsid"
    exit 1
}
ARMS=$((ARMS + 1))

# Arm 2: and there is a branch that runs the guard WITHOUT it. A probe whose
# only outcome is the setsid path would be a probe that changes nothing.
grep -q 'exec bash "\$_p"' "$B" || {
    echo "violation:preflight-setsid-probe:no-fallback-exec-without-setsid"
    exit 1
}
ARMS=$((ARMS + 1))

# Arm 3: BOTH summary lines carry the isolation mode. Pinning only the refusal
# line would let a green run hide a degraded one, which is the direction that
# costs something.
# NEEDLE ANCHORED ON THE VERDICT PREFIX AND THE VARIABLE, not on the `ran=`
# body. macbookair, 2026-09-22: an arm keyed on an incidental detail of what it
# reads rather than on the property it asserts will match nothing and red for
# the wrong reason. The first form required `ran=` immediately after the prefix;
# 1353-ryhq replaces exactly that body with per-category counts, so the arm
# matched nothing on the merged tree — a red that said nothing about isolation=,
# which is the property this arm exists to assert. This form matches both the
# pre-1353 line and the merged one.
_ok="$(grep -c 'echo "ok:preflight:.*\$_pf_iso' "$B")"
_no="$(grep -c 'echo "refused:preflight:.*\$_pf_iso' "$B")"
if [ "$_ok" -lt 1 ] || [ "$_no" -lt 1 ]; then
    echo "violation:preflight-setsid-probe:a-summary-line-does-not-name-the-isolation-mode"
    exit 1
fi
ARMS=$((ARMS + 1))

# Arm 4: the reason setsid is there must survive. 295-306 records what was
# measured without it — nine survivors from one door run, and broken 124
# detection reporting timeouts as refusals — and a later reader who deletes the
# probe in favour of dropping setsid should meet that comment first.
grep -q 'setsid + background makes pid == pgid' "$B" || {
    echo "violation:preflight-setsid-probe:the-rationale-for-setsid-was-removed"
    exit 1
}
ARMS=$((ARMS + 1))

echo "ok:preflight-setsid-probe:$ARMS"

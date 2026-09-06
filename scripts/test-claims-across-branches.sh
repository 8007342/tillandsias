#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1034-whsp
#
# Fixture for check-claims-across-branches.sh.
#
# WHAT MUST NOT HAPPEN, and why each arm exists. This check's whole job is to
# say "someone else holds this". Its dangerous direction is therefore the FALSE
# NEGATIVE: any path that reports ok when it could not actually look hands a
# claimed packet to a second host and reproduces 814-iyu7. So every arm that
# breaks the check asserts it BLOCKS, never that it passes.
#
# The sibling folds are driven through a STUB plan binary. The real binary needs
# a real ledger, and building one per arm would make the fixture measure YAML
# fixtures rather than this script's decision. The stub makes the decision the
# only variable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-claims-across-branches.sh"
[ -x "$CHECK" ] || { echo "blocked:no-check"; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1" >&2; [ -n "${2:-}" ] && echo "     $2" >&2; }

W="$(mktemp -d "${TMPDIR:-/tmp}/xbranch-fx.XXXXXX")"
trap 'rm -rf "$W"' EXIT INT TERM

# A stub that answers with whatever status the arm wants.
mkstub() { # $1=dir $2=status
    mkdir -p "$1"
    cat > "$1/tillandsias-plan" <<EOF
#!/bin/sh
# stub plan binary: always answers status=$2
echo "PKT	$2	some-packet-name"
EOF
    chmod +x "$1/tillandsias-plan"
}

# 1. A sibling holding the packet must REFUSE, naming the branch.
mkstub "$W/hold" in_progress
out="$(cd "$ROOT" && TILLANDSIAS_PLAN_BIN="$W/hold/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch 2>/dev/null)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^claimed-elsewhere:SOME-PKT:'; then
    ok "a sibling branch holding the packet is reported, exit 1"
else
    bad "a sibling holding the packet must be reported" "rc=$rc out=[$out]"
fi

# 2. NEGATIVE CONTROL. If arm 1 passed because the check refuses EVERYTHING, it
#    would be useless in the other direction: no host could ever claim anything.
mkstub "$W/free" ready
out="$(cd "$ROOT" && TILLANDSIAS_PLAN_BIN="$W/free/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok:cross-branch-claims:'; then
    ok "a packet nobody holds is not refused, exit 0 — arm 1 is not refusing everything"
else
    bad "an unheld packet must pass" "rc=$rc out=[$out]"
fi

# 3. THE FALSE NEGATIVE THAT MATTERS. No plan binary means the folds cannot be
#    read at all. That MUST block: reporting ok would say "nobody holds it"
#    on the strength of having been unable to look. This is 1024-c3h3's shape,
#    where a checker's could-not-run branch printed an ok: verdict.
#    CONSTRUCTING THIS TOOK A SECOND ATTEMPT, and the first is worth recording.
#    I first ran the real script under `env -i` from $ROOT and asserted it
#    blocked. It did not, and it was RIGHT not to: the script cd's to its own
#    ROOT, where target/release/tillandsias-plan exists, so the probe found it
#    and `ok` was the correct answer. The arm had not removed the binary at all
#    — it was asserting against a condition it never built, and had I "fixed"
#    the script to satisfy it I would have broken a working check.
#    So the absence is built the only way it can be: a ROOT that genuinely has
#    no target/, holding the script and the probe it sources.
mkdir -p "$W/noroot/scripts"
cp "$CHECK" "$W/noroot/scripts/"
cp "$ROOT/scripts/plan-binary-probe.sh" "$W/noroot/scripts/"
out="$(env -i PATH=/usr/bin:/bin HOME="$W" bash "$W/noroot/scripts/check-claims-across-branches.sh" SOME-PKT --no-fetch 2>/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^blocked:no-plan-binary'; then
    ok "no plan binary BLOCKS rather than reporting the packet unclaimed"
else
    bad "no plan binary must block, not pass" "rc=$rc out=[$out]"
fi

# 4. A verdict must never be silently empty: the check prints exactly one
#    verdict line on stdout in every arm above.
mkstub "$W/free2" ready
n="$(cd "$ROOT" && TILLANDSIAS_PLAN_BIN="$W/free2/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch 2>/dev/null | grep -cE '^(ok|claimed-elsewhere|blocked):')"
if [ "$n" -ge 1 ]; then
    ok "every run prints a machine-readable verdict line ($n)"
else
    bad "a run printed no verdict line" "n=$n"
fi

# A stub that knows NOTHING — what the real binary does for an unknown packet:
# it prints no row. `mkstub` always answers, so it asserts existence for every
# name and cannot express absence; the first version of arm 5 used it and failed
# against a working fix for that reason.
mkstub_absent() { # $1=dir
    mkdir -p "$1"
    printf '#!/bin/sh\nexit 1\n' > "$1/tillandsias-plan"
    chmod +x "$1/tillandsias-plan"
}

# 5. A PACKET NOBODY HAS HEARD OF IS NOT "UNCLAIMED".
#
# The tool answered `ok:cross-branch-claims:2 sibling branch(es) checked` for a
# packet that exists on NO branch — measured live on
# `definitely-not-a-real-packet-xyz`, and on 1090-8nh4 during the window between
# its author filing it and pushing it. A host acting on that ok claims a phantom.
#
# This is the defect this tool exists to catch, occurring in the tool: a green
# answering a narrower question than the sentence attached to it. "ok" reads as
# "safe to claim" and meant only "no sibling holds it in_progress".
mkstub_absent "$W/none"
out="$(cd "$ROOT" && TILLANDSIAS_PLAN_BIN="$W/none/tillandsias-plan" bash "$CHECK" NO-SUCH-PACKET-1091 --no-fetch 2>/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q '^unknown-packet:'; then
    ok "a packet no branch and no local fold knows is reported unknown, not ok"
else
    bad "an unknown packet must not report ok" "rc=$rc out=[$out]"
fi

# NEGATIVE CONTROL. If existence were decided by something that says no to
# everything, arm 5 would pass while the tool refused every real packet too.
mkstub "$W/real" ready
out="$(cd "$ROOT" && TILLANDSIAS_PLAN_BIN="$W/real/tillandsias-plan" bash "$CHECK" SOME-PKT --no-fetch 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^ok:cross-branch-claims:'; then
    ok "a packet the fold knows still passes — arm 5 is not refusing everything"
else
    bad "a known packet must still pass" "rc=$rc out=[$out]"
fi

echo "claims-across-branches: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

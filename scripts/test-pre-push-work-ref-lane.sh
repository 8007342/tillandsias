#!/usr/bin/env bash
# @trace order:1315-4a7j, spec:ci-release
#
# THE DEFECT THIS CLOSES was a contradiction across three documents, not a bug
# in any one of them. Until 2026-09-20 the hook said a work ref was "the GATED
# hand-off and demands the stamp" (pre-push-local-gate.sh:154), the methodology
# said pre_push_gate EXCLUDES work/<order> while calling it "a GATED commit",
# and branch_namespaces.creation_regex admitted no `work/` ref at all. So a work
# branch was simultaneously required to be gated, exempt from the gate, and not
# a legal ref name.
#
# THE MEASURED CONSEQUENCE: 92 salvage/* refs against 34 work/* on origin —
# hosts using the emergency RESCUE lane as their everyday branch, because it was
# the only ungated one. And 13 of ~46 land runs on 2026-09-20 needed a retry,
# one needed three; on this host, 10 gate cycles across two slices with 5 lost
# purely to RE-GATING AN UNCHANGED TREE after another host pushed first.
#
# PHASE 1 IS MIGRATION, NOT ENFORCEMENT (operator, 2026-09-20). Nothing new
# refuses. The work lane opens, the deciders still RUN on a work push and WARN,
# and every refusal carries the COMPLETE preferred workflow rather than a
# fragment of it. ARM 2 is the arm that keeps this honest: the integration gate
# on linux-next is UNCHANGED, because there is no server CI and the local gate
# is the only safety net.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOOK="$ROOT/scripts/hooks/pre-push-local-gate.sh"
[ -x "$HOOK" ] || [ -f "$HOOK" ] || { printf 'skip:work-ref-lane:no-hook\n'; exit 0; }

# A commit that certainly has NO gate stamp: a sha from this repo's history is
# fine as an identifier — the hook's stamp check keys on the TREE, and no stamp
# exists for a synthetic push line.
SHA="$(git rev-parse HEAD 2>/dev/null || echo 0000000000000000000000000000000000000000)"
ZERO=0000000000000000000000000000000000000000

# run_hook <remote-ref> -> prints combined output; echoes rc on the last line
run_hook() {
    local out rc
    out="$(printf 'refs/heads/x %s %s %s\n' "$SHA" "$1" "$ZERO" \
        | timeout 300 bash "$HOOK" origin "file://$TMP/scaffold.git" 2>&1)"
    rc=$?
    printf '%s\n__RC__%s\n' "$out" "$rc"
}

# run_hook_line <local-sha> <remote-ref> <remote-sha> — one raw push line, for
# the arms where the DELETION shape matters. run_hook above always sends a
# create/update; a deletion is a local sha of all zeros, and the regression
# below lives entirely in that shape.
run_hook_line() {
    local out rc
    out="$(printf 'refs/heads/x %s %s %s\n' "$1" "$2" "$3" \
        | timeout 300 bash "$HOOK" origin "file://$TMP/scaffold.git" 2>&1)"
    rc=$?
    printf '%s\n__RC__%s\n' "$out" "$rc"
}

# ---------------------------------------------------------------- ARM 0
# A SALVAGE-ONLY PUSH IS NOT THE WORK LANE. REGRESSION ARM, and the regression
# was mine.
#
# WHAT HAPPENED. 1315-4a7j added the work lane by accumulating `_all_work`
# alongside `_all_salvage` and `_all_marker`. The `refs/heads/salvage/*` arm
# cleared `_all_marker` and NOT `_all_work`, so a push made ONLY of salvage refs
# satisfied `_all_work -eq 1`, took the work lane, and the work lane WARNS where
# it used to refuse. The casualty was 874-w2gc's deletion protection: deleting a
# salvage ref — which may be the ONLY copy of rescued work, the whole reason
# that refusal exists — was downgraded to a warning and the push proceeded.
#
# HOW IT WAS CAUGHT, and this is the part worth keeping. It was NOT caught by
# ./build.sh --check, which was green on this change through the gate, the
# hand-off and the cross-platform compile. It was caught by
# litmus:salvage-net-roundtrip in the PRE-BUILD LITMUS TIER, which --check never
# runs (the doctrine recorded in methodology/convergence.yaml under 1282-rkkm,
# written the same evening by the host that then shipped this). Fixed in
# 6080e8365 before the landing; this arm is what makes the fix falsifiable
# instead of trusted.
#
# WHY A DELETION AND NOT ANY SALVAGE PUSH. An ordinary salvage push is exempt by
# design (872-c9nd) and exits 0 either way, so it CANNOT distinguish the two
# classifications — an arm built on it would pass against the defect. The
# deletion is the one salvage shape whose correct answer is a REFUSAL, so it is
# the only shape where "work lane" and "salvage lane" give different verdicts.
a0="$(run_hook_line "$ZERO" refs/heads/salvage/yoga/20260921-probe "$SHA")"
rc0="${a0##*__RC__}"
case "$a0" in
    *"874-w2gc"*)
        if [ "${rc0:-0}" -ne 0 ]; then
            ok "ARM 0 (regression): a salvage-only DELETION push is REFUSED naming 874-w2gc — a salvage-only push is not the work lane"
        else
            bad "ARM 0 (regression): the 874-w2gc text was printed but the hook EXITED 0 — the refusal became a warning, which is the 1315-4a7j regression exactly"
        fi ;;
    *"warn:pre-push:"*)
        bad "ARM 0 (regression): a salvage-only deletion took the WORK LANE and warned (rc=$rc0) — _all_work is not cleared on the salvage arm" ;;
    *)
        bad "ARM 0 (regression): a salvage-only deletion was neither refused for 874-w2gc nor warned (rc=$rc0); the deletion protection is unreachable" ;;
esac

# ARM 0b (CONTROL): the same deletion WITH the documented override proceeds.
# Without this, ARM 0 would pass against a hook that refused every salvage push
# unconditionally — which would break the rescue lane while looking protective.
a0b="$(TILLANDSIAS_SALVAGE_DELETE_OK=1 run_hook_line "$ZERO" refs/heads/salvage/yoga/20260921-probe "$SHA")"
rc0b="${a0b##*__RC__}"
if [ "${rc0b:-1}" -eq 0 ]; then
    ok "ARM 0b (control): the same deletion with TILLANDSIAS_SALVAGE_DELETE_OK=1 is accepted — ARM 0 pins the protection, not a blanket refusal"
else
    bad "ARM 0b (control): the documented override did not clear the refusal (rc=$rc0b) — the rescue lane is broken, which is worse than the regression"
fi

# ---------------------------------------------------------------- ARM 1
# A WORK PUSH WITH NO STAMP IS ACCEPTED, THE DECIDERS WARN, THE HOOK EXITS 0.
a1="$(run_hook refs/heads/work/1315-4a7j)"
rc1="${a1##*__RC__}"
if [ "${rc1:-1}" -ne 0 ]; then
    bad "ARM 1: a work/<order> push with no stamp was REFUSED (rc=$rc1) — the lane is not open, and hosts keep using salvage/ as their everyday branch"
elif printf '%s' "$a1" | grep -q 'prefer work branches'; then
    if printf '%s' "$a1" | grep -qE '^warn:pre-push:'; then
        ok "ARM 1: a work push with no stamp is ACCEPTED, each red decider prints warn:pre-push:<decider>: and the affordance follows"
    else
        ok "ARM 1: a work push with no stamp is ACCEPTED and carries the affordance (no decider was red on this tree, so no warn line to show)"
    fi
else
    bad "ARM 1: the work push was accepted but carries NO affordance — a lane nobody is told about is the salvage situation again"
fi

# ---------------------------------------------------------------- ARM 2
# THE INTEGRATION GATE IS UNCHANGED. This is the arm that stops Phase 1 from
# quietly becoming "nothing is gated": there is no server CI.
a2="$(run_hook refs/heads/linux-next)"
rc2="${a2##*__RC__}"
if [ "${rc2:-0}" -eq 0 ]; then
    bad "ARM 2: the SAME stampless commit was ACCEPTED to linux-next — the work lane has disabled the only safety net the trunk has"
elif printf '%s' "$a2" | grep -qi 'stamp'; then
    ok "ARM 2: the same stampless commit is still REFUSED to linux-next for the missing stamp — the integration gate is untouched"
else
    ok "ARM 2: the same commit is still refused to linux-next (rc=$rc2)"
fi

# ---------------------------------------------------------------- ARM 3
# THE RACE REFUSAL CARRIES THE AFFORDANCE. This is the refusal a host hits
# having done nothing wrong, and without a named alternative the only move it
# suggests is the retry that produced five wasted gate cycles in one day.
LAND="$ROOT/scripts/land-on-platform-branch.sh"
if [ ! -f "$LAND" ]; then
    bad "ARM 3: the land tool is absent, so the race refusal cannot be checked"
elif grep -A16 'attempts-exhausted' "$LAND" | grep -q 'prefer work branches'; then
    ok "ARM 3: the trunk-race refusal carries the affordance naming work/<order>, the PR command and the skill"
else
    bad "ARM 3: the race refusal still reports only that origin is fast — the reader has a green slice and no named way in"
fi

# ---------------------------------------------------------------- ARM 4
# THE METHODOLOGY ADMITS THE REF — and still refuses a stray, or the sweep that
# reaps abandoned refs loses its grammar.
MD="$ROOT/methodology/multi-host-development.yaml"
rx="$(grep -m1 '\^refs/heads/(main' "$MD" 2>/dev/null | sed 's/^ *//')"
if [ -z "$rx" ]; then
    bad "ARM 4: creation_regex not found in $MD"
else
    good=0; stray=0
    printf '%s' "$rx" | grep -q 'work/' && good=1
    if [ "$good" -eq 1 ]; then
        # the grammar must be the packet-id shape, not a wildcard
        if printf '%s' "$rx" | grep -qE 'work/\[0-9\]\{[0-9],[0-9]\}-\[a-z0-9\]\{4\}'; then
            ok "ARM 4: creation_regex admits work/<order> by the PACKET-ID grammar, so work/foo remains a stray the sweep reaps"
        else
            bad "ARM 4: creation_regex admits work/ but not by the packet-id grammar — work/foo would become a legal ref and the sweep loses its grammar"
        fi
    else
        bad "ARM 4: creation_regex still admits no work/ ref, so every work branch is a stray the sweep never reaps"
    fi
fi

# ---------------------------------------------------------------- ARM 5
# THE PROVENANCE CLASSIFIER COUNTS A SCAFFOLD HISTORY CORRECTLY. The flip to
# enforcement is meant to rest on this number, so the number has to be right
# before anyone is asked to act on it.
PROV="$ROOT/scripts/check-landing-provenance.sh"
S="$TMP/scaffold"; mkdir -p "$S"
(
  cd "$S" && git init -q . && git config user.email t@t && git config user.name t
  mkdir -p plan/index.d scripts
  echo a > plan/index.d/f.yaml && git add -A && git commit -q -m "plan(x): a fragment"      # plan
  echo b > scripts/s.sh       && git add -A && git commit -q -m "Merge pull request #1 from work/1234-abcd"  # queue
  echo c > scripts/t.sh       && git add -A && git commit -q -m "relay(osx-next): plan-only"                 # relay
  echo d > scripts/u.sh       && git add -A && git commit -q -m "fix(9999-zzzz): a direct push"              # direct
) >/dev/null 2>&1
if [ ! -f "$PROV" ]; then
    bad "ARM 5: the provenance classifier is absent, so the enforcement trigger has no number behind it"
else
    line="$(TILLANDSIAS_PROVENANCE_REPO="$S" TILLANDSIAS_PROVENANCE_REF=HEAD bash "$PROV" 50.years 2>/dev/null | head -1)"
    if printf '%s' "$line" | grep -q 'queue=1' \
       && printf '%s' "$line" | grep -q 'plan=1' \
       && printf '%s' "$line" | grep -q 'relay=1' \
       && printf '%s' "$line" | grep -q 'direct=1'; then
        ok "ARM 5: the classifier counts one of each correctly ($line)"
    else
        bad "ARM 5: the classifier miscounted the scaffold — got: ${line:-<nothing>}"
    fi
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf 'ok:work-ref-lane:%d/%d\n' "$pass" "$((pass + fail))"
    exit 0
fi
printf 'blocked:work-ref-lane:%d-failed-of-%d\n' "$fail" "$((pass + fail))"
exit 1

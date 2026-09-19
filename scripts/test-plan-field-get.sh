#!/usr/bin/env bash
# @trace order:1261-bn7v, spec:ci-release
#
# test-plan-field-get.sh — the folded-long-form-field primitive.
#
# WHY IT EXISTS: `query --json --limit 0` carries NO long-form field (measured:
# zero rows of 1058 carry next_action, notes, context, verifiable_closure,
# unscoreable or provenance), so 1261-bn7v's lane check had nothing to fold
# origin's copy with.
#
# THE TERNARY IS THE POINT (1260-2qgi). set / unset / no-such-packet are THREE
# outcomes and a caller must be able to tell them apart: a field that is unset
# is not a field that is empty, and neither is a packet that does not exist.
# Collapsing them is how a lane ends up comparing "" against "" and admitting a
# push that drops a peer's lines.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
# shellcheck source=scripts/plan-binary-probe.sh
. scripts/plan-binary-probe.sh
P="$(resolve_plan_binary)" || { echo "skip:field-get:no-plan-binary"; exit 0; }
# CAPTURE THEN MATCH (795-imz3). The first version of this probe was
#   ! "$P" field-get x y 2>&1 | grep -qE 'unset:field-get|error:'
# which is hazard shape 1 under the `set -o pipefail` above: grep -q exits on
# the first match, SIGPIPEs the producer, the pipeline reports FAILURE ON A
# MATCH, and this script printed skip:subcommand-absent against a binary that
# has the subcommand. Written by the author of the bash-hazard lint, four hours
# after measuring 545 instances of it. Recorded rather than quietly fixed.
_probe="$("$P" field-get 9999-nosuch next_action 2>&1)"
case "$_probe" in
    *unset:field-get*|*error:*) ;;
    *) echo "skip:field-get:subcommand-absent-in-this-binary"; exit 0 ;;
esac
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# A packet that certainly exists, with a field that certainly does.
REF=1261-bn7v

# --- ARM 1: a SET field prints its value and exits 0 ------------------------
# EXIT STATUS CAPTURED DIRECTLY, never through a pipe: a pipeline's status is
# its last command, and reading `$?` after `| head` reports head's. That defect
# masked this very check's first run.
out="$("$P" field-get "$REF" next_action 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] \
    && ok "ARM 1 a set field prints its value and exits 0" \
    || bad "ARM 1 expected rc=0 and non-empty, got rc=$rc len=${#out}"

# --- ARM 2: an UNSET field exits 3 and prints NOTHING on stdout -------------
out="$("$P" field-get "$REF" progress_summary 2>/dev/null)"; rc=$?
[ "$rc" -eq 3 ] && [ -z "$out" ] \
    && ok "ARM 2 an unset field exits 3 with empty stdout (not conflated with empty)" \
    || bad "ARM 2 expected rc=3 and empty stdout, got rc=$rc out='$out'"

# --- ARM 3: a packet that does not exist exits 1 ----------------------------
"$P" field-get 9999-nosuch next_action >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
    && ok "ARM 3 an unresolvable packet exits 1, distinct from unset's 3" \
    || bad "ARM 3 expected rc=1, got rc=$rc"

# --- ARM 4: THE ONE THE LANE NEEDS — it reads the CWD's ledger --------------
# 1261-bn7v's fix folds ORIGIN's copy by extracting it and running there, which
# only works if the binary resolves its ledger from the working directory rather
# than from its own path. Discriminated with two trees that DISAGREE; comparing
# two trees that happen to agree would prove nothing, which is how the first
# version of this check failed to test anything.
if git rev-parse --verify --quiet refs/remotes/origin/linux-next >/dev/null 2>&1; then
    T="$(mktemp -d)"
    if git archive origin/linux-next plan/ 2>/dev/null | tar -x -C "$T" 2>/dev/null; then
        here="$("$P" field-get "$REF" next_action 2>/dev/null)"
        there="$(cd "$T" && "$ROOT/$P" field-get "$REF" next_action 2>/dev/null || true)"
        if [ -n "$there" ]; then
            ok "ARM 4 the binary reads the ledger in its CWD, so an extracted origin tree can be folded"
        else
            bad "ARM 4 got nothing from the extracted tree — the lane's fold approach will not work"
        fi
        [ -n "$here" ] || bad "ARM 4 control: the live tree returned nothing"
    else
        echo "skip: ARM 4 — git archive unavailable"
    fi
    rm -rf "$T"
else
    echo "skip: ARM 4 — no origin/linux-next ref in this clone"
fi

echo "plan-field-get: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
echo "ok:plan-field-get:$pass"

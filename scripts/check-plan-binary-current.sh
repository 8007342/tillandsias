#!/usr/bin/env bash
# check-plan-binary-current.sh — does the plan binary this host RUNS carry the
# 1079-qb8k claim refusal? (order 1079-qb8k, 2026-09-05)
#
# @trace plan/index.yaml
#
# WHY A SCRIPT AND NOT A PARAGRAPH. Three hosts derived this probe by hand in
# one evening and each found a way the previous one was blind. A command that
# lives in prose gets retyped, and a retyped command is a new command with none
# of the corrections. So it lives here and the corrections travel with it.
#
# WHAT IT IS FOR. yoga's 1079-qb8k landed a REFUSAL: `append-event --type claim`
# now refuses when the packet is not in_progress and names the missing
# `set-field`. A refusal only exists in the binary a host actually runs, and on
# 2026-09-05 THREE OF THREE HOSTS CHECKED WERE STALE — macuahuitl, lenovinha and
# yolanda, the last built before the fix, with the fix present in its SOURCES.
# Two of the four rows the packet was filed on were caused by that staleness.
# A fix on trunk that no host executes is a fix nobody has.
#
# WHY THE OBVIOUS CHECKS DO NOT WORK. Measured on macuahuitl: the stale and
# fresh copies both reported a capability count of 58. A version string, a
# capability set and a `grep` of the sources ALL report healthy. Only behaviour
# discriminates — so this asks the tool to do the thing it should refuse.
#
# THE FOUR CONDITIONS, each earned by a host that got it wrong first:
#
#   1. MINT THE AGENT ID (scripts/agent-identity.sh). lenovinha's first probe was
#      refused for a non-canonical agent_id and NEVER REACHED the claim-status
#      check. A bare rc=1 read as healthy. A wrong refusal looks exactly like a
#      right one.
#   2. ASSERT THE TARGET IS `ready` FIRST. The same command legitimately
#      SUCCEEDS on an in_progress packet, so a probe against the wrong target
#      proves nothing in either direction.
#   3. GREP THE REFUSAL TEXT, NOT THE EXIT CODE. Condition 1 is why: several
#      distinct refusals share rc=1.
#   4. ASSERT ZERO SIDE EFFECTS, and check what else is on PATH. A second stale
#      copy shadowing the one you fixed is invisible otherwise.
#
# AND IT WRITES NOTHING TO THE LEDGER. lenovinha raised the objection that the
# behavioural probe pollutes when it FAILS — a stale binary writes a fragment,
# and "remember to delete it" is the property we spend our days removing. The
# answer is `--index`: the probe runs against a scratch COPY of the plan, so a
# stale binary's write lands there and the repository is untouched. Verified
# with a positive control on macuahuitl 2026-09-05: an ACCEPTED write against
# the scratch index moved its fragment count 545 -> 546 while plan/index.d
# stayed at 545 and `git status` stayed clean. Without that control, "the repo
# did not change" would be indistinguishable from "nothing was written at all".
#
# Grammar, one line on stdout, exit 0 only on ok:
#   ok:plan-binary-current:<path>
#   stale:plan-binary-no-claim-refusal:<path>
#   blocked:<reason>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"

BIN="${TILLANDSIAS_PLAN_BIN:-$(command -v tillandsias-plan 2>/dev/null || echo "$ROOT/target/release/tillandsias-plan")}"
[ -x "$BIN" ] || { echo "blocked:no-plan-binary:$BIN"; exit 2; }

# Condition 4, part two: a second copy shadowing the one under test.
#
# `type -a`, NOT `command -v -a`. The first version of this line used
# `command -v -a`, which this bash does not support: it printed nothing, exited
# clean, and reported `copies=0` on a host that has TWO. Caught within a minute
# of writing it because the number was printed and looked wrong — which is
# print_the_denominator applied to a sub-check inside the probe that exists to
# catch blind sub-checks. A zero from an unsupported flag is indistinguishable
# from a zero from an empty PATH.
# DISTINCT paths, not lines: `type -a` prints one line per PATH entry, and this
# host has ~/.local/bin four times over, so the raw line count said 4 for ONE
# binary. Third correction to this one sub-check, each found by printing the
# number and looking at it rather than by reading the code.
_copies="$(type -a tillandsias-plan 2>/dev/null | sed 's/.* is //' | sort -u | grep -c .)"

# Condition 2: a target that is genuinely `ready`, asked of the tool itself.
TARGET="${1:-}"
if [ -z "$TARGET" ]; then
    TARGET="$("$BIN" ready 2>/dev/null | awk '$2=="ready"{print $1; exit}')"
fi
[ -n "$TARGET" ] || { echo "blocked:no-ready-packet-to-probe"; exit 2; }
_st="$("$BIN" status "$TARGET" 2>/dev/null | awk '{print $2}')"
[ "$_st" = "ready" ] || { echo "blocked:probe-target-not-ready:$TARGET:$_st"; exit 2; }

# Condition 1: a canonical agent id, minted rather than typed.
if [ -x scripts/agent-identity.sh ]; then
    AGENT="$(bash scripts/agent-identity.sh 2>/dev/null | tail -1)"
fi
[ -n "${AGENT:-}" ] || AGENT="linux-$(hostname -s 2>/dev/null || echo host)-claude-$(date -u +%Y%m%dt%H%M%Sz)"

# The ledger-isolating scratch copy. A stale binary's write lands HERE.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/plan-binary-probe.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
cp plan/index.yaml "$SCRATCH/index.yaml" 2>/dev/null || { echo "blocked:no-plan-index"; exit 2; }
cp -r plan/index.d "$SCRATCH/index.d" 2>/dev/null || true
_before="$(ls "$SCRATCH/index.d" 2>/dev/null | wc -l | tr -d ' ')"
_repo_before="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"

_out="$("$BIN" --index "$SCRATCH/index.yaml" append-event "$TARGET" --type claim \
        --summary "probe: does this binary carry the 1079-qb8k claim refusal" \
        --host "$(hostname -s 2>/dev/null || echo host)" --agent "$AGENT" \
        --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>&1)"

_after="$(ls "$SCRATCH/index.d" 2>/dev/null | wc -l | tr -d ' ')"
_repo_after="$(ls plan/index.d 2>/dev/null | wc -l | tr -d ' ')"

# Condition 4: the repository must be untouched whatever the verdict.
if [ "$_repo_before" != "$_repo_after" ]; then
    echo "blocked:probe-wrote-to-the-repository:$_repo_before->$_repo_after"; exit 2
fi

# Condition 3: WHICH refusal. A claim-status refusal names the packet and the
# missing set-field; an identity refusal names the agent id and proves nothing.
if printf '%s' "$_out" | grep -q 'a claim EVENT does not claim'; then
    echo "ok:plan-binary-current:$BIN copies=$_copies scratch_fragments=$_before->$_after target=$TARGET"
    exit 0
fi
if printf '%s' "$_out" | grep -qiE 'agent[_ ]?id|identity'; then
    echo "blocked:probe-refused-on-identity-not-claim-status — the probe never reached the check (see 756-hn3a); mint the id with scripts/agent-identity.sh"
    exit 2
fi
if [ "$_before" != "$_after" ]; then
    echo "stale:plan-binary-no-claim-refusal:$BIN copies=$_copies scratch_fragments=$_before->$_after target=$TARGET"
    exit 1
fi
echo "blocked:unrecognised-verdict:$(printf '%s' "$_out" | head -1 | cut -c1-120)"
exit 2

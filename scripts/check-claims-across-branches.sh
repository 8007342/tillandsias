#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:1034-whsp
#
# check-claims-across-branches.sh — is this packet claimed on a SIBLING branch?
#
# WHY THIS EXISTS, MEASURED ON tlatoanis-macbook-air 2026-09-05.
#
# 1034-whsp was filed as a LATENCY bug: "a claim is invisible for as long as its
# push takes". yoga measured the push and reframed it once — the retry loop costs
# 18-56ms, the pre-push hook costs ~6.5s, and the actionable rule became "the
# claim commit must contain the claim fragment and nothing else".
#
# THE SECOND-HOST MEASUREMENT REFRAMES IT AGAIN, AND THE PUSH IS NOT THE PROBLEM.
# A claim from a platform host does not become visible to a trunk host when the
# push lands. It becomes visible when the COORDINATOR RELAYS the platform branch
# into linux-next, and that is a different clock entirely:
#
#   claim push, osx-next, claim-only diff ....... 12.0s total
#     (0.7s refused for the mandated linux-next merge, 0.5s merge, 10.8s push;
#      the plan-only lane DID accept it, scoped past the merge — 1056-5344 and
#      1060-7mmm already made the lane merge-aware, so the lane is not the gap)
#   osx-next -> linux-next relay gaps ........... 19m to 2h02m across the last 9
#   time since the last relay when this was written ... 6h28m
#   two of this host's own claims, still unseen ....... 1h55m and 2h11m
#
# So the invisibility window is not ten minutes (the filed incident) and not
# twelve seconds (the push). For a platform host it is the relay interval, and
# it is worst exactly when the trunk is busiest — the property the packet's
# title names, arriving through topology rather than through retries.
#
# MEASURED DIRECTLY, folding each branch's ledger with `--index`:
#   origin/linux-next fold ... 1034-whsp  ready        <- what a linux host selects on
#   this checkout ............ 1034-whsp  in_progress  <- I hold it
# 8 of this host's fragments were absent from linux-next at that moment.
#
# WHY (a), (b) AND (d) FROM THE PACKET CANNOT FIX IT. They all optimise the push:
# more retries, a fresher read before pushing, an always-mergeable claim push.
# The push already completes in seconds. Nothing done on the pushing host makes a
# fragment appear on a branch nobody has merged yet.
#
# WHY THIS IS (c), THE SMALLEST VERSION. `git ls-remote origin 'refs/tillandsias/*'`
# returns ZERO refs, so the out-of-band store the packet hoped the mirror already
# carried does not exist. Rather than build one, this reads what is ALREADY
# published: every platform branch is on origin, and a claim is a fragment file.
# Unioning the fragment listings across the sibling branches answers "is anyone
# else holding this" without any new channel, and without waiting for a relay.
#
# NOT A LOCK. It closes the window from a relay interval to one fetch; two hosts
# claiming inside the same fetch still collide, and the timestamp rule still
# arbitrates. It converts an hours-wide race into a seconds-wide one.
#
# Verdict grammar, one line on stdout:
#   ok:cross-branch-claims:<n> sibling branch(es) checked          exit 0
#   claimed-elsewhere:<packet>:<branch>:<host>                     exit 1
#   blocked:<reason>                                               exit 2
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "blocked:no-root"; exit 2; }

PACKET="${1:-}"
[ -n "$PACKET" ] || { echo "usage: check-claims-across-branches.sh <packet-id-or-order> [--no-fetch]" >&2; exit 2; }
NO_FETCH=0
[ "${2:-}" = "--no-fetch" ] && NO_FETCH=1

# RESOLVE THE VALIDATOR THROUGH THE SHARED PROBE, AND REFUSE WITHOUT ONE.
# This is 1024-c3h3 in advance: that fixture asked a checker a question from a
# directory where its cwd-relative probe found nothing, the checker took its
# "not built" branch, and the SKIP read as a pass — including on a negative
# control, which then agreed for the wrong reason. Here the wrong reason would
# be worse: "no binary" would print "nobody else holds this packet" and hand a
# claimed packet to a second host. An unanswerable question must be BLOCKED, not
# answered optimistically.
# shellcheck source=scripts/plan-binary-probe.sh
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN_BIN="$(resolve_plan_binary 2>/dev/null)" || PLAN_BIN=""
case "$PLAN_BIN" in ./*) PLAN_BIN="$ROOT/${PLAN_BIN#./}" ;; esac
if [ -z "$PLAN_BIN" ]; then
    echo "blocked:no-plan-binary — cannot fold a sibling branch's ledger, so this says NOTHING about who holds a packet; build with ./build.sh (never read this as unclaimed)" >&2
    echo "blocked:no-plan-binary"
    exit 2
fi

SIBLINGS="linux-next windows-next osx-next"
CURRENT="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || CURRENT=""

if [ "$NO_FETCH" = 0 ]; then
    # One fetch, all siblings. This is the whole cost of the remedy.
    git fetch -q origin $SIBLINGS 2>/dev/null || {
        # A fetch failure must not read as "nobody else holds it" — that is the
        # false-negative this check exists to prevent, and it would be silent.
        echo "blocked:fetch-failed — cannot see sibling branches, so this says NOTHING about who holds $PACKET" >&2
        echo "blocked:fetch-failed"
        exit 2
    }
fi

checked=0
found=""
for b in $SIBLINGS; do
    git rev-parse --verify -q "origin/$b" >/dev/null 2>&1 || continue
    [ "$b" = "$CURRENT" ] && continue
    checked=$((checked + 1))
    # Fold that branch's ledger and ask it directly, rather than grepping
    # fragments: status is LWW and a later fragment can release a claim, so the
    # raw presence of a claim fragment is NOT the same question (635-i6vm).
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/xbranch.XXXXXX")"
    if git archive "origin/$b" plan/index.yaml plan/index.d 2>/dev/null | tar -x -C "$tmp" 2>/dev/null; then
        st="$("$PLAN_BIN" --index "$tmp/plan/index.yaml" status "$PACKET" 2>/dev/null | awk '{print $2}')"
        if [ "$st" = in_progress ]; then
            found="${found:+$found }$b"
        fi
    fi
    rm -rf "$tmp"
done

if [ -n "$found" ]; then
    for b in $found; do
        echo "claimed-elsewhere:$PACKET:$b"
    done
    echo "  A sibling branch holds this packet in_progress and your fold has not seen it yet." >&2
    echo "  It is NOT yours to implement. Arbitration is by claim TIMESTAMP, not push order:" >&2
    echo "  if yours is earlier you continue; if theirs is earlier you release and reroute." >&2
    exit 1
fi
echo "ok:cross-branch-claims:$checked sibling branch(es) checked"

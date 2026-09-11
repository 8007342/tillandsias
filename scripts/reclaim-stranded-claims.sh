#!/usr/bin/env bash
# @trace spec:ci-release
#
# reclaim-stranded-claims.sh — return abandoned claims to `ready`.
#
# Order 641-e2qa exit criterion 2. check-stranded-in-progress.sh REPORTS the
# leak; this closes it. Without a reclaim path the stranded set regenerates
# continuously, because every interrupted cycle adds one and nothing ever
# removes one.
#
# WHY THIS IS SAFE TO AUTOMATE WHEN CLOSING IS NOT
# ------------------------------------------------
# 641-e2qa refuses to auto-CLOSE a stranded packet, and that refusal stands:
# deciding work is finished requires checking exit criteria against the tree,
# and a wrong guess marks unfinished work done — silently, permanently, and in
# the direction nobody audits.
#
# Reclaiming is the opposite direction and the asymmetry is the whole argument.
# Returning a packet to `ready` cannot destroy work: the code, the commits and
# the events all survive untouched. The worst case is that a still-live claim is
# released and two hosts briefly consider the same packet — which the lease
# protocol already treats as normal and safe (advisory, CRDT-friendly,
# idempotent-merge). Being wrong here costs a duplicated glance. Being wrong
# about closure costs the work.
#
# EVIDENCE REQUIRED (order 662-s9z5: evaluated by `tillandsias-plan
# expire-claims`, the one owner of claim-age semantics — see the delegation
# block below). A packet is reclaimed only when its newest recorded activity
# is older than the TTL (default 24h, the fleet claim TTL). A packet with no
# parseable activity at all is refused as `unknown-age` — absent evidence is
# not evidence of abandonment, and that case wants a human. Every candidate
# NOT reclaimed gets a typed `refused` line; an apply run that reclaims
# nothing exits non-zero.
#
# DRY RUN BY DEFAULT. `--apply` writes the reclaim fragment (via the binary).
#

set -uo pipefail

TTL_HOURS=24
APPLY=0
NOW_EPOCH=""

# ORDER 943-unii. Every flag that takes a value REQUIRES one, and says so.
#
# All three arms below were silently wrong, and two of them HUNG. The old
# parser was:
#     --ttl-hours) TTL_HOURS="${2:-4}"; shift 2 ;;
#     --now)       NOW_EPOCH="${2:-}";  shift 2 ;;
# With the flag passed bare, `shift 2` has only one argument to consume. Under
# `set -uo pipefail` (no `-e`) that shift FAILS, leaves `$#` unchanged, and the
# `while` re-reads the same argument forever — measured 2026-08-30: both
# `--ttl-hours` and `--now` with no value hang until killed.
#
# The `${2:-4}` fallback made it worse in principle: had the shift succeeded it
# would have silently reaped at 4 HOURS instead of the documented 24, returning
# live claims six times too early. In a reaper the meta-orchestration skill
# already warns "launders finished work into lost work" (833-fpe7), a typo must
# not be able to choose a shorter TTL.
#
# TTL is validated HERE rather than left to expire-claims: passing `abc`
# through made the wrapper print `mode=refused-expire-claims-failed`, blaming
# the tool for the caller's argument.
need_value() { # need_value <flag> <count-remaining>
    if [ "$2" -lt 2 ]; then
        echo "summary: candidates=0 reclaimed=0 refused=0 mode=refused-missing-value:$1" >&2
        echo "usage: reclaim-stranded-claims.sh [--apply] [--ttl-hours N] [--now EPOCH]" >&2
        exit 2
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --ttl-hours) need_value "$1" "$#"; TTL_HOURS="$2"; shift 2 ;;
        --ttl-hours=*) TTL_HOURS="${1#--ttl-hours=}"; shift ;;
        --now) need_value "$1" "$#"; NOW_EPOCH="$2"; shift 2 ;;   # test seam: fixed clock
        *) echo "usage: reclaim-stranded-claims.sh [--apply] [--ttl-hours N] [--now EPOCH]" >&2; exit 2 ;;
    esac
done

case "$TTL_HOURS" in
    ''|*[!0-9]*)
        echo "summary: candidates=0 reclaimed=0 refused=0 mode=refused-bad-ttl:$TTL_HOURS" >&2
        echo "--ttl-hours needs a positive integer (hours); got '$TTL_HOURS'" >&2
        exit 2 ;;
esac
[ "$TTL_HOURS" -gt 0 ] 2>/dev/null || {
    echo "summary: candidates=0 reclaimed=0 refused=0 mode=refused-bad-ttl:$TTL_HOURS" >&2
    echo "--ttl-hours needs a POSITIVE integer; 0 would reclaim every live claim" >&2
    exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

command -v jq >/dev/null 2>&1 || { echo "summary: candidates=0 reclaimed=0 mode=refused-missing-jq"; exit 1; }
# Order 721-nyev: resolve by EXECUTION through the shared probe. The old loop
# took the first candidate with an executable bit, which on a shared
# Windows/WSL checkout selects the Linux ELF sitting beside the runnable .exe.
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
PLAN="$(resolve_plan_binary || true)"
[ -n "$PLAN" ] || { echo "summary: candidates=0 reclaimed=0 mode=refused-no-plan-binary"; exit 1; }

[ -n "$NOW_EPOCH" ] || NOW_EPOCH="$(date -u +%s)"

# ── ORDER 662-s9z5: delegate to the binary; refuse in types; never no-op ─────
#
# The old body re-derived claim age by grepping the ledger for `type: claim`
# events — which do not exist: the claim convention writes `type: note` with a
# "claimed for cycle" summary. Every candidate was silently skipped, and
# `candidates=7 reclaimed=0 mode=apply` read like a successful run for an
# entire session. That is the shell-side brittle parsing 456 eliminated,
# reinvented — so the fix is DELETION, not repair (discard-over-repair):
# `tillandsias-plan expire-claims` (672-bz7u) already owns claim-age from the
# folded ledger, writes proper reclaim fragments with attribution events, and
# fails conservative on unknown age. This wrapper adds what 662-s9z5's exit
# criteria demand on top: a TYPED verdict for every candidate it will not
# touch, and a non-zero exit when an apply run reclaims nothing — silence is
# no longer an available outcome.
#
# TTL default is now 24h, matching the fleet claim TTL (672-bz7u, the skill's
# claim protocol). The old 4h default borrowed claim-ledger-node's NODE lease
# TTL — the wrong scale for packet claims by a factor of six.
#
# GRAMMAR:
#   ^reclaim\t<order>\t<packet_id>\t<last_activity_ts>$      (reclaimed, or would be)
#   ^refused\t<order>\t<packet_id>\t(within-ttl|unknown-age)$
#   ^summary: candidates=<n> reclaimed=<n> refused=<n> mode=(dry-run|apply)$
# Exit: 0 clean; 1 when mode=apply && candidates>0 && reclaimed==0 (typed
# refusals above say WHY per candidate), and on infra refusals as before.

# Candidate set FIRST — an apply run mutates the ledger, and a snapshot taken
# after it would count the packets just reclaimed as never-candidates (the
# fixture's case 1 caught exactly that ordering on this rewrite's first draft).
stranded="$(./scripts/check-stranded-in-progress.sh 2>/dev/null \
    | awk -F'\t' '$1=="stranded"{print $2 "\t" $4}')"

expire_args=(expire-claims --ttl-hours "$TTL_HOURS")
[ -n "$NOW_EPOCH" ] && expire_args+=(--now-epoch "$NOW_EPOCH")
# ORDER 1067-24q6: expire-claims now defaults to dry-run and WRITING IS
# OPT-IN. This wrapper must ask for the write explicitly; passing neither
# flag would make `--apply` a silent no-op that still reported reclaims.
if [ "$APPLY" -eq 1 ]; then
    expire_args+=(--write)
else
    expire_args+=(--dry-run)
fi
if ! expire_out="$("$PLAN" "${expire_args[@]}" 2>&1)"; then
    echo "summary: candidates=0 reclaimed=0 refused=0 mode=refused-expire-claims-failed"
    printf '%s\n' "$expire_out" | head -3 >&2
    exit 1
fi

candidates=0
reclaimed=0
refused=0
while IFS=$'\t' read -r order pid; do
    [ -n "$pid" ] || continue
    candidates=$((candidates + 1))
    line="$(printf '%s\n' "$expire_out" \
        | awk -F'\t' -v p="$pid" '($1=="expired-claim" || $1=="expire-candidate") && $3==p {print; exit}')"
    if [ -n "$line" ]; then
        printf 'reclaim\t%s\t%s\t%s\n' "$order" "$pid" "$(printf '%s' "$line" | cut -f4)"
        reclaimed=$((reclaimed + 1))
    elif printf '%s\n' "$expire_out" | awk -F'\t' -v p="$pid" '$1=="unknown-age" && $3==p {found=1} END{exit !found}'; then
        printf 'refused\t%s\t%s\tunknown-age\n' "$order" "$pid"
        refused=$((refused + 1))
    else
        # The reaper kept it: newest recorded activity is inside the TTL. A
        # fresh or legitimately long-running claim is DECLINED, loudly — the
        # negative control 662-s9z5 demands.
        printf 'refused\t%s\t%s\twithin-ttl\n' "$order" "$pid"
        refused=$((refused + 1))
    fi
done <<< "$stranded"

# Surface the fragment the binary wrote (apply) so the caller commits it.
printf '%s\n' "$expire_out" | grep '^fragment: ' || true

printf 'summary: candidates=%s reclaimed=%s refused=%s mode=%s\n' \
    "$candidates" "$reclaimed" "$refused" "$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)"

if [ "$APPLY" -eq 1 ] && [ "$candidates" -gt 0 ] && [ "$reclaimed" -eq 0 ]; then
    # Every candidate has a typed refusal above; the non-zero exit is what
    # stops a no-op sweep from reading as success in a cycle log (662-s9z5
    # exit criterion 2).
    exit 1
fi
exit 0

#!/usr/bin/env bash
# @trace order:833-fpe7, spec:meta-orchestration
# bash-dialect: pure-3.2 — no mapfile, no ${var,,} on arrays; the mtime
# comparison uses the test builtin's -nt against a TZ=UTC touch anchor, so no
# GNU/BSD stat or date probing is needed. Marker consumed by
# scripts/check-bash-dialect.sh (761-g36m).
#
# check-resumable-claim-dirt.sh — deterministic detector for the SECOND known
# dirt class: this host's OWN in-flight claimed work, left uncommitted when a
# previous cycle was interrupted between implement and commit.
#
# WHY (order 833-fpe7). Meta-orchestration's dirty-start refusal treats every
# status-visible dirty path as immutable sibling/operator work. Applied to the
# host's own interrupted claimed work that refusal deadlocks: every later cycle
# refuses identically, the finished work never lands, the packets stay
# double-invisible (641-e2qa), and expire-claims eventually launders the CLAIM
# away while doing nothing about the DIFF — so the next host reimplements it
# (814-iyu7 by a second route). Order 540 solved this shape once for
# launch-generated opsx dirt (check-opsx-generated-dirt.sh); this is the
# analogous detector for claim dirt.
#
# WHAT A PASS MEANS — AND DOES NOT MEAN. `resumable:` says "safe for THIS cycle
# to review and land under the order-540 re-snapshot sequence". It is NOT
# auto-commit: proving an edit IMPLEMENTS the packet it sits beside is an agent
# judgment, not a machine fact, and a detector claiming otherwise would be the
# order-531 shape. What the detector removes is the deadlock, not the review.
#
# Grammar (exactly one line):
#   ^(resumable:<order>(,<order>)*|ok:clean-tree|unattributable:.*)$
#
# Exit codes (order-540 conventions):
#   0 — resumable: every condition below holds; the named orders are this
#       host's live claims the dirt is attributable to
#   4 — ok:clean-tree (nothing dirty; nothing to attribute)
#   3 — unattributable: at least one condition failed — REFUSE, unchanged
#   2 — usage / infra error (worktree or ledger could not be inspected)
#
# ALL of these must hold for exit 0 (each is a fixture-pinned negative
# control in litmus:resumable-claim-dirt-shape):
#   1. every dirty path is TRACKED — an untracked file is not attributable to
#      a claim;
#   2. the folded ledger names >=1 live claim OWNED BY THIS HOST
#      (`tillandsias-plan expire-claims --list-live`: claim-convention event
#      host, never last-toucher; both claim and newest activity inside the
#      expire-claims TTL);
#   3. every dirty path's mtime is strictly AFTER the OLDEST such claim's ts
#      (equal-to-the-second counts as before: fail closed).
#
# Fixture seams (same idiom as the sibling guards):
#   TILLANDSIAS_PLAN_BIN            explicit plan binary (plan-binary-probe.sh)
#   TILLANDSIAS_WORKSTATION         this host's name override (agent-identity
#                                   precedence; default: hostname -s, lowered)
#   TILLANDSIAS_RESUME_NOW_EPOCH    forwarded to the binary as --now-epoch
#   TILLANDSIAS_RESUME_TTL_HOURS    forwarded as --ttl-hours
set -uo pipefail

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "unattributable:not-a-git-repo"
    exit 2
fi
cd "$ROOT" || { echo "unattributable:worktree-unreadable"; exit 2; }

# ── collect dirty paths (tracked edits vs untracked) ─────────────────────────
tracked_paths=()
untracked_paths=()
while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ "${line:0:2}" == "??" ]]; then
        untracked_paths+=("${line:3}")
    else
        tracked_paths+=("${line:3}")
    fi
done < <(git status --porcelain=v1 -z --untracked-files=all | tr '\0' '\n')

if [[ ${#tracked_paths[@]} -eq 0 && ${#untracked_paths[@]} -eq 0 ]]; then
    echo "ok:clean-tree"
    exit 4
fi

# ── condition 1: untracked dirt is never claim dirt ──────────────────────────
if [[ ${#untracked_paths[@]} -gt 0 ]]; then
    joined=""
    for p in "${untracked_paths[@]}"; do
        [[ -n "$joined" ]] && joined="$joined,"
        joined="$joined$p"
    done
    echo "unattributable:untracked-paths:$joined"
    exit 3
fi

# ── condition 2: a live claim owned by this host ─────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/plan-binary-probe.sh"
# 851-cduu: ensure, not resolve — this guard was silently inert for 11 hours
# on macuahuitl behind a binary preflight had built BEFORE sibling work was
# pulled mid-cycle: every dirty tree answered unattributable:plan-query-failed,
# reopening the wedge 833-fpe7 had just closed. Freshness is verified here, at
# the point of use, in whatever locus is executing this guard.
PLAN="$(ensure_fresh_plan_binary)" && _fresh_rc=0 || _fresh_rc=$?
if [ "$_fresh_rc" -eq 2 ]; then
    echo "unattributable:stale-plan-binary"
    exit 2
elif [ "$_fresh_rc" -ne 0 ]; then
    echo "unattributable:no-runnable-plan-binary"
    exit 2
fi

host="${TILLANDSIAS_WORKSTATION:-}"
if [[ -z "$host" ]]; then
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
fi
host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
if [[ -z "$host" ]]; then
    echo "unattributable:host-unresolvable"
    exit 2
fi

plan_args=(expire-claims --dry-run --list-live)
[[ -n "${TILLANDSIAS_RESUME_NOW_EPOCH:-}" ]] && plan_args+=(--now-epoch "$TILLANDSIAS_RESUME_NOW_EPOCH")
[[ -n "${TILLANDSIAS_RESUME_TTL_HOURS:-}" ]] && plan_args+=(--ttl-hours "$TILLANDSIAS_RESUME_TTL_HOURS")
if ! claims_raw="$("$PLAN" "${plan_args[@]}" 2>/dev/null)"; then
    echo "unattributable:plan-query-failed"
    exit 2
fi

own_orders=""
oldest_ts=""
while IFS=$'\t' read -r tag order _pid claim_host claim_ts _last; do
    [[ "$tag" == "live-claim" ]] || continue
    claim_host="$(printf '%s' "$claim_host" | tr '[:upper:]' '[:lower:]')"
    [[ "$claim_host" == "$host" ]] || continue
    [[ -n "$own_orders" ]] && own_orders="$own_orders,"
    own_orders="$own_orders$order"
    if [[ -z "$oldest_ts" || "$claim_ts" < "$oldest_ts" ]]; then
        oldest_ts="$claim_ts"
    fi
done <<< "$claims_raw"

if [[ -z "$own_orders" ]]; then
    echo "unattributable:no-live-claim-by-this-host"
    exit 3
fi

# ── condition 3: every dirty path postdates the oldest own claim ─────────────
# The anchor file gets the claim's UTC timestamp via TZ=UTC touch -t, and the
# comparison is the test builtin's -nt — no GNU/BSD stat or date dialects.
# The ledger ts is fixed-width `YYYY-MM-DDTHH:MM:SSZ`; anything else refuses.
if [[ ! "$oldest_ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "unattributable:claim-ts-unparseable:$oldest_ts"
    exit 2
fi
touch_stamp="${oldest_ts:0:4}${oldest_ts:5:2}${oldest_ts:8:2}${oldest_ts:11:2}${oldest_ts:14:2}.${oldest_ts:17:2}"
anchor="$(mktemp "${TMPDIR:-/tmp}/resumable-claim-anchor.XXXXXX")" || {
    echo "unattributable:anchor-unwritable"
    exit 2
}
trap 'rm -f "$anchor"' EXIT
if ! TZ=UTC touch -t "$touch_stamp" "$anchor" 2>/dev/null; then
    echo "unattributable:anchor-unstampable:$touch_stamp"
    exit 2
fi

stale=""
for p in "${tracked_paths[@]}"; do
    # A path deleted in the worktree has no mtime to attribute; refuse.
    if [[ ! -e "$p" ]] || [[ ! "$p" -nt "$anchor" ]]; then
        [[ -n "$stale" ]] && stale="$stale,"
        stale="$stale$p"
    fi
done
if [[ -n "$stale" ]]; then
    echo "unattributable:paths-predate-claim:$stale"
    exit 3
fi

echo "resumable:$own_orders"
exit 0

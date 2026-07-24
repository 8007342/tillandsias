#!/bin/bash
# freshness: refreshed 2026-07-24 forge-bigpickle-20260724
set -uo pipefail

# @trace spec:meta-orchestration
# claim-ledger-node.sh: lightweight in-flight claim/lease for plan/index.yaml
# node-closure (ledger-hygiene) edits (plan order 62).
#
# Today only destructive e2e work is serialized (scripts/with-smoke-lock.sh).
# Read-only meta-orch cycles that close or hygiene-edit a plan/index.yaml node
# have no way to see that a concurrent cycle is already re-deriving the same
# closure, so two agents independently produce the identical edit (see
# plan/issues/agent-concurrency-collisions-2026-06-20.md, Observation
# 2026-06-20T19:05Z). The collision is idempotent (no data loss) but wastes a
# whole cycle's effort — exactly the velocity drag the reduction engine must
# capture and reduce.
#
# This is a CRDT-friendly *advisory* lease, not a mutex on the file: it respects
# the stable-ID + idempotent-merge preconditions in
# methodology/between-commits-work-discipline.yaml. A claimant atomically
# reserves a node ID before re-deriving its closure; a concurrent claimant on
# the same ID is told the closure is already in flight and can skip it. The
# underlying plan-merge remains idempotent, so a missed/expired lease never
# corrupts state — at worst two agents converge on the same edit, which is safe.
#
# Atomicity primitive: mkdir(2) of a per-node lease directory (same primitive
# the lockdir fallback in with-smoke-lock.sh relies on). Exactly one of N
# concurrent mkdir calls on the same path succeeds.
#
# Verdict grammar (exactly one line on stdout, falsifiable):
#   ^(claimed|reclaimed|in-flight|released|free):[a-z0-9._/-]+$
#
#   claimed:<id>     lease acquired by this caller (exit 0)
#   reclaimed:<id>   a stale/expired lease was taken over by this caller (exit 0)
#   in-flight:<id>   a live lease is held by another caller; skip re-derivation (exit 1)
#   released:<id>    this caller's lease was released (exit 0)
#   free:<id>        status: no live lease is held (exit 1)
#
# Subcommands:
#   claim   <node-id>   (default) try to reserve the node
#   release <node-id>   drop a lease this host holds
#   status  <node-id>   report in-flight:<id> (exit 0) or free:<id> (exit 1)
#
# Env seams (used by litmus:ledger-node-claim-shape):
#   TILLANDSIAS_LEDGER_LEASE_ROOT       lease root dir (default runtime/tmp)
#   TILLANDSIAS_LEDGER_LEASE_TTL_SECS   lease TTL seconds (default 14400 = 4h)
#   TILLANDSIAS_LEDGER_LEASE_ID         opaque lease/agent id recorded in holder

LEASE_ROOT="${TILLANDSIAS_LEDGER_LEASE_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks/ledger-nodes}"
LEASE_TTL="${TILLANDSIAS_LEDGER_LEASE_TTL_SECS:-14400}"
LEASE_ID="${TILLANDSIAS_LEDGER_LEASE_ID:-$(hostname 2>/dev/null || echo unknown)-$$}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/claim-ledger-node.sh [claim|release|status] NODE_ID
Reserve a plan/index.yaml node closure to avoid duplicated ledger-hygiene work.
EOF
}

# Map an arbitrary node id (may contain '/') to a single safe path segment.
lease_path() {
  local id="$1" safe
  safe="$(printf '%s' "$id" | sed 's#/#__#g')"
  printf '%s/%s.lease' "$LEASE_ROOT" "$safe"
}

now_epoch() { date -u +%s; }

write_holder() {
  local dir="$1" id="$2" acquired expires
  acquired="$(now_epoch)"
  expires="$((acquired + LEASE_TTL))"
  {
    printf 'node_id=%s\n' "$id"
    printf 'lease_id=%s\n' "$LEASE_ID"
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$(hostname 2>/dev/null || printf unknown)"
    printf 'acquired_epoch=%s\n' "$acquired"
    printf 'expires_epoch=%s\n' "$expires"
    printf 'acquired_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$dir/holder"
}

# Echo the holder's expires_epoch (or empty if unreadable/missing).
holder_expires() {
  local dir="$1"
  [ -r "$dir/holder" ] || { printf ''; return; }
  sed -n 's/^expires_epoch=//p' "$dir/holder" | head -1
}

# A lease dir is stale (reclaimable) only when we can prove it is past its TTL.
# A missing/unreadable holder is treated as LIVE, not stale: between a winning
# mkdir and its write_holder there is a brief window where the holder does not
# yet exist, and a loser that reclaimed on "no holder" would destroy the
# winner's lease and break the single-winner guarantee. The orphan case (process
# killed mid-claim, holder never written) is still reclaimed via the lease dir's
# own mtime once it ages past the TTL.
lease_is_stale() {
  local dir="$1" exp mtime
  exp="$(holder_expires "$dir")"
  if [[ "$exp" =~ ^[0-9]+$ ]]; then
    [ "$(now_epoch)" -ge "$exp" ]           # expired => stale (0), else live (1)
    return
  fi
  # No usable holder yet: fall back to the dir's age. Live during the write
  # window; reclaimable only once it has sat orphaned for a full TTL.
  mtime="$(stat -c %Y "$dir" 2>/dev/null || echo '')"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1    # cannot age it => assume live
  [ "$(now_epoch)" -ge "$((mtime + LEASE_TTL))" ]
}

cmd_claim() {
  local id="$1" dir
  dir="$(lease_path "$id")"
  mkdir -p "$LEASE_ROOT"
  if mkdir "$dir" 2>/dev/null; then
    write_holder "$dir" "$id"
    echo "claimed:$id"
    return 0
  fi
  # Path exists: live lease, or a stale one we may take over.
  if lease_is_stale "$dir"; then
    rm -rf "$dir"
    if mkdir "$dir" 2>/dev/null; then
      write_holder "$dir" "$id"
      echo "reclaimed:$id"
      return 0
    fi
    # Lost the reclaim race to another caller; treat as in-flight.
  fi
  echo "in-flight:$id"
  return 1
}

cmd_release() {
  local id="$1" dir
  dir="$(lease_path "$id")"
  rm -rf "$dir"
  echo "released:$id"
  return 0
}

cmd_status() {
  local id="$1" dir
  dir="$(lease_path "$id")"
  if [ -d "$dir" ] && ! lease_is_stale "$dir"; then
    echo "in-flight:$id"
    return 0
  fi
  echo "free:$id"
  return 1
}

main() {
  local sub="claim" id=""
  case "${1:-}" in
    claim|release|status) sub="$1"; shift ;;
    -h|--help) usage; exit 0 ;;
    "") usage; exit 64 ;;
  esac
  id="${1:-}"
  [ -n "$id" ] || { usage; exit 64; }
  [[ "$id" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "node id has unsupported characters: $id" >&2; exit 64; }
  case "$sub" in
    claim)   cmd_claim "$id" ;;
    release) cmd_release "$id" ;;
    status)  cmd_status "$id" ;;
  esac
}

main "$@"

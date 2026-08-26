#!/bin/bash
# freshness: refreshed 2026-07-24 forge-bigpickle-20260724
set -uo pipefail

# @trace spec:meta-orchestration
#
##Agent-Affordance:
##  use_when: "you need to claim/release/check a plan/index.yaml node before editing it"
##  cost: "instant (mkdir-based, no network)"
##  output: "one line matching ^(claimed|reclaimed|in-flight|released|free):[a-z0-9._/-]+$"
##  see_also: "scripts/drain-queue.sh (orchestrates sequential claims)"
##  example: "scripts/claim-ledger-node.sh claim order-427a"
##  example: "scripts/claim-ledger-node.sh status order-427a"
##  example: "scripts/claim-ledger-node.sh release order-427a"
#
# claim-ledger-node.sh: lightweight in-flight claim/lease for plan/index.yaml
# node-closure (ledger-hygiene) edits (plan order 62).
#
# WHY: Read-only meta-orch cycles that close or hygiene-edit a plan/index.yaml
# node have no way to see that a concurrent cycle is already re-deriving the
# same closure, so two agents independently produce the identical edit. The
# collision is idempotent but wastes a whole cycle's effort. This script
# serializes node-closure claims so concurrent agents skip work that is
# already in flight.
#
# HOW: Atomic mkdir(2) of a per-node lease directory. Leases expire after 4h
# (configurable via TILLANDSIAS_LEDGER_LEASE_TTL_SECS). Stale leases are
# auto-reclaimed. This is advisory (CRDT-friendly), not a mutex.
#
# Verdict grammar (exactly one line on stdout, falsifiable):
#   ^(claimed|reclaimed|in-flight|released|free|unknown):[a-z0-9._/-]+$
#
#   claimed:<id>     lease acquired by this caller (exit 0)
#   reclaimed:<id>   a stale/expired lease was taken over by this caller (exit 0)
#   in-flight:<id>   a live lease is held by another caller; skip re-derivation (exit 1)
#   released:<id>    this caller's lease was released (exit 0)
#   free:<id>        status: no live lease is held (exit 1)
#   unknown:<id>     claim only: no packet resolves to this id — NOT leased (exit 2)
#
# WHY `unknown` EXISTS (order 790-u8x6). `claim` used to answer `claimed:<id>`
# for ANY string, including one that names no packet. Observed live 2026-08-17:
# a cycle claimed a three-packet bundle from ids guessed off their titles and
# got `claimed:squid-proxy-version-bump-past-6-9` and
# `claimed:crane-deps-stability-and-fleet-binary-cache` — neither of which
# exists (the real ids are `proxy-squid-...` and `crane-deps-stability-and-
# binary-cache`). The cycle then believed it held leases on two packets that
# were in fact unleased and claimable by any sibling, and the output was
# byte-indistinguishable from success. An advisory lease is weak coordination
# BY DESIGN and that is correct; an advisory lease on a node that does not
# exist is ZERO coordination reported as success, which is the
# reads-as-protective-and-is-not class (723-ydmk) landing on the coordination
# layer. The blast radius is precisely what the lease prevents: two hosts doing
# the same work (plan/issues/agent-concurrency-collisions-2026-06-20.md).
#
# `release` and `status` stay PERMISSIVE and never resolve the id: a packet
# that was obsoleted or renamed after a lease was taken still needs releasing,
# and a stale lease you cannot drop is worse than a phantom one.
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
#   TILLANDSIAS_LEDGER_CLAIM_INDEX      ledger the claim resolves ids against
#                                       (default <repo>/plan/index.yaml). A
#                                       FIXTURE index — not a skip switch — is
#                                       the seam, so the litmus exercises this
#                                       exact resolution path against a
#                                       controlled corpus rather than bypassing
#                                       it (same shape as AUTH_PROBE).

SCRIPT_DIR_CLN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_CLN="$(cd "$SCRIPT_DIR_CLN/.." && pwd)"

LEASE_ROOT="${TILLANDSIAS_LEDGER_LEASE_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/tillandsias-locks/ledger-nodes}"
LEASE_TTL="${TILLANDSIAS_LEDGER_LEASE_TTL_SECS:-14400}"
LEASE_ID="${TILLANDSIAS_LEDGER_LEASE_ID:-$(hostname 2>/dev/null || echo unknown)-$$}"
CLAIM_INDEX="${TILLANDSIAS_LEDGER_CLAIM_INDEX:-$REPO_ROOT_CLN/plan/index.yaml}"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/claim-ledger-node.sh [claim|release|status] NODE_ID

Reserve a plan/index.yaml node closure to avoid duplicated ledger-hygiene work.

Subcommands:
  claim   <node-id>   Try to reserve the node (exit 0 on success, 1 if in-flight)
  release <node-id>   Drop a lease this host holds (exit 0)
  status  <node-id>   Report in-flight:<id> (exit 0) or free:<id> (exit 1)

Options:
  -h, --help    Show this help message

Verdict (exactly one line on stdout):
  claimed:<id>     lease acquired by this caller
  reclaimed:<id>   stale/expired lease was taken over
  in-flight:<id>   live lease held by another caller — SKIP this node
  released:<id>    this caller's lease was released
  free:<id>        no live lease is held
  unknown:<id>     claim only: no packet resolves to this id — nothing leased (exit 2)

Env:
  TILLANDSIAS_LEDGER_LEASE_ROOT       lease root dir (default /tmp/tillandsias-locks/ledger-nodes)
  TILLANDSIAS_LEDGER_LEASE_TTL_SECS   lease TTL seconds (default 14400 = 4h)
  TILLANDSIAS_LEDGER_LEASE_ID         opaque lease/agent id (default hostname-pid)
  TILLANDSIAS_LEDGER_CLAIM_INDEX      ledger claim resolves ids against (default plan/index.yaml)
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

# Does a packet resolve to this id? Delegates to `tillandsias-plan status`,
# which is the authority: it resolves BOTH a packet_id and an order token, and
# it reads the FOLDED ledger (base + plan/index.d/ fragments), so a packet
# filed minutes ago in a fragment resolves correctly. A grep over the base
# alone would refuse those — a false refusal is worse than the phantom lease
# this fix removes.
#
# Returns 0 exists, 1 does not exist, 2 UNVERIFIABLE (no binary or no index).
# Deliberately no pipeline: `producer | grep -q` under `set -o pipefail`
# (line 3) is load-flaky via SIGPIPE, which cost the fleet a red trunk gate
# four times in one night (order 792-ksr8).
node_exists() {
  local id="$1" plan_bin probe_dir
  [ -f "$CLAIM_INDEX" ] || return 2
  probe_dir="$SCRIPT_DIR_CLN/plan-binary-probe.sh"
  [ -r "$probe_dir" ] || return 2
  # shellcheck source=/dev/null
  . "$probe_dir"
  plan_bin="$(resolve_plan_binary)" || return 2
  [ -n "$plan_bin" ] || return 2
  "$plan_bin" --index "$CLAIM_INDEX" status "$id" >/dev/null 2>&1
  case "$?" in
    0) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_claim() {
  local id="$1" dir
  # Resolve BEFORE taking the lease: a lease on a node that does not exist is
  # zero coordination reported as success (790-u8x6).
  node_exists "$id"
  case "$?" in
    1)
      echo "unknown:$id"
      echo "  no packet resolves to '$id' in $CLAIM_INDEX — nothing was leased." >&2
      echo "  Check the id with: tillandsias-plan status $id" >&2
      return 2
      ;;
    2)
      # Cannot verify (no built binary, or no ledger here). Degrade LOUDLY and
      # still lease — refusing would break claims on a fresh checkout, and the
      # 702-68zj precedent is that stale/absent host state is skipped by name,
      # never silently and never as a violation.
      echo "  note: claim could not verify '$id' (no resolvable plan binary or ledger at $CLAIM_INDEX); leasing unverified" >&2
      ;;
  esac
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

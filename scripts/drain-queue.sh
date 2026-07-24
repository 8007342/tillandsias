#!/usr/bin/env bash
# drain-queue.sh — Local sequential agent queue drain.
#
# Operator-invoked script that parses plan/index.yaml for ready packets
# and launches fresh agent sessions via ./repeat to drain them one at a time.
#
# Usage:
#   ./scripts/drain-queue.sh [--limit <n>] [--release <v0.4|v0.5>] [--tag <tag>] [--dry-run]
#
# Options:
#   --limit <n>       Max packets to drain (default: unlimited)
#   --release <ver>   Only packets for this desired_release (e.g. v0.4, v0.5)
#   --tag <tag>       Only packets whose capability_tags include this tag
#   --dry-run         Print the drain plan without executing
#
# Each cycle runs: ./repeat --prompt "Use the /advance-work-from-plan skill to work on packet <order> <packet_id>" --times 1
#
# The script logs results to drain-queue-<date>.log and respects the forge
# cycle budget (one packet per cycle for forge hosts).

set -euo pipefail

LIMIT=""
RELEASE_FILTER=""
TAG_FILTER=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --release) RELEASE_FILTER="$2"; shift 2 ;;
    --tag) TAG_FILTER="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

LOGFILE="drain-queue-$(date -u '+%Y%m%d').log"
DRAIN_COUNT=0

log() {
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "$ts $1" | tee -a "$LOGFILE"
}

# Extract ready packets: order, packet_id, desired_release, capability_tags
extract_ready_packets() {
  awk '
  /^[[:space:]]*- packet_id:/ {
    if (ready == 1 && pid != "") print ord "\t" pid "\t" rel "\t" tags
    gsub(/.*: */, ""); pid=$0; rel=""; tags=""; ready=0
  }
  /^[[:space:]]*order:/ { gsub(/.*: */, ""); ord=$0 }
  /^[[:space:]]*desired_release:/ { gsub(/.*: */, ""); rel=$0 }
  /^[[:space:]]*capability_tags:/ {
    gsub(/.*: */, "");
    gsub(/\[|\]/, "");
    tags=$0
  }
  /^[[:space:]]*status: ready/ { ready=1 }
  END { if (ready == 1 && pid != "") print ord "\t" pid "\t" rel "\t" tags }
  ' plan/index.yaml
}

log "=== Drain Queue Started ==="
log "Host: ${TILLANDSIAS_HOST_KIND:-unknown}"
log "Branch: $(git branch --show-current)"

# Build the packet list
PACKETS=$(extract_ready_packets)

# Apply filters
if [[ -n "$RELEASE_FILTER" ]]; then
  PACKETS=$(echo "$PACKETS" | awk -F'\t' -v rel="$RELEASE_FILTER" '$3 == rel')
fi
if [[ -n "$TAG_FILTER" ]]; then
  PACKETS=$(echo "$PACKETS" | awk -F'\t' -v tag="$TAG_FILTER" '$4 ~ tag')
fi

TOTAL=$(echo "$PACKETS" | grep -c '[^[:space:]]' || true)
log "Ready packets found: $TOTAL"
[[ -n "$RELEASE_FILTER" ]] && log "  Filtered by release: $RELEASE_FILTER"
[[ -n "$TAG_FILTER" ]] && log "  Filtered by tag: $TAG_FILTER"

if [[ "$TOTAL" -eq 0 ]]; then
  log "No ready packets to drain."
  exit 0
fi

# Show drain plan
log "--- Drain Plan ---"
echo "$PACKETS" | while IFS=$'\t' read -r ord pid rel tags; do
  log "  [$ord] $pid (release=$rel, tags=$tags)"
done
log "---"

if $DRY_RUN; then
  log "Dry run — exiting without executing."
  exit 0
fi

# Drain loop
echo "$PACKETS" | while IFS=$'\t' read -r ord pid rel tags; do
  [[ -z "$ord" ]] && continue

  if [[ -n "$LIMIT" ]] && [[ "$DRAIN_COUNT" -ge "$LIMIT" ]]; then
    log "Limit reached ($LIMIT). Stopping."
    break
  fi

  log "=== Draining [$ord] $pid ==="

  # Claim the node first
  CLAIM_RESULT=$(scripts/claim-ledger-node.sh claim "$pid" 2>&1 || true)
  log "Claim: $CLAIM_RESULT"

  if [[ "$CLAIM_RESULT" == in-flight:* ]]; then
    log "SKIP: $pid is already claimed by another agent."
    continue
  fi

  # Run one agent cycle for this packet
  PROMPT="Use the /advance-work-from-plan skill to work on packet $ord $pid"
  log "Prompt: $PROMPT"

  if ./repeat --prompt "$PROMPT" --times 1 --timeout 30m 2>&1 | tee -a "$LOGFILE"; then
    log "COMPLETE: [$ord] $pid"
    scripts/claim-ledger-node.sh release "$pid" 2>/dev/null || true
  else
    log "FAILED: [$ord] $pid (exit code $?)"
    scripts/claim-ledger-node.sh release "$pid" 2>/dev/null || true
  fi

  DRAIN_COUNT=$((DRAIN_COUNT + 1))
  log "Progress: $DRAIN_COUNT / ${LIMIT:-unlimited}"
done

log "=== Drain Queue Complete: $DRAIN_COUNT packets processed ==="

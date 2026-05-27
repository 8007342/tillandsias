#!/usr/bin/env bash
# @trace spec:default-image, spec:forge-as-only-runtime
# @trace methodology/forge-diagnostics.yaml (piggyback_protocol)
# @trace plan/issues/forge-diagnostics-automation-2026-05-27.md
#   (forge-diagnostics/e2e-piggyback-orchestration)
#
# forge-diagnostics-annex.sh — NON-BLOCKING diagnostics annex for slow E2E /
# runtime-litmus forge launches.
#
# Contract (methodology/forge-diagnostics.yaml piggyback_protocol):
#   - Any slow E2E run that already launched a forge MAY run ONE diagnostics
#     prompt during the same forge lifetime.
#   - In a single CI / orchestrator cycle, only the FIRST eligible run executes
#     the full prompt; later eligible runs append a checksum-based skip note
#     pointing to the first raw log (dedupe via current-prompt.sha256).
#   - This is a NON-BLOCKING annex: it NEVER fails its caller. Capture/launch
#     problems become recorded findings, not parent-E2E failures. The script
#     therefore always exits 0 (except on explicit --help/usage).
#
# Usage:
#   scripts/forge-diagnostics-annex.sh            # run the annex (with dedup)
#   scripts/forge-diagnostics-annex.sh --reset    # clear the cycle marker
#                                                  # (call once at cycle start)
#   scripts/forge-diagnostics-annex.sh --status   # print marker state, exit 0
#
# A "cycle" is delimited by --reset (the runtime-litmus / CI orchestrator calls
# it at the start of a fold). Within a cycle the first call captures; the rest
# skip. If the prompt content changes mid-cycle (different sha), the next call
# re-captures (the prompt is the unit of work).

set -uo pipefail   # NOT -e: the annex must not abort its caller on a substep.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DIAG_DIR="target/forge-diagnostics"
PROMPT_FILE="plan/diagnostics/forge-diagnostics-prompt.txt"
MARKER="${DIAG_DIR}/current-prompt.sha256"
SKIP_LOG="${DIAG_DIR}/cycle-skips.log"
DISTILL="${SCRIPT_DIR}/distill-forge-diagnostics.sh"

log() { echo "[forge-annex] $*"; }

mkdir -p "$DIAG_DIR"

case "${1:-}" in
  -h|--help)
    sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  --reset)
    rm -f "$MARKER"
    log "cycle marker cleared ($MARKER) — next annex run will capture"
    exit 0
    ;;
  --status)
    if [[ -f "$MARKER" ]]; then
      log "marker present: $(cat "$MARKER")"
    else
      log "no marker — next annex run will capture"
    fi
    exit 0
    ;;
  "")
    : # fall through to the annex run
    ;;
  *)
    log "unknown flag: $1 (see --help)"
    exit 0   # non-blocking: never fail the caller, even on bad args
    ;;
esac

# --- prompt presence (precondition; non-fatal) -----------------------------
if [[ ! -s "$PROMPT_FILE" ]]; then
  log "FINDING: prompt file missing/empty ($PROMPT_FILE) — annex skipped"
  exit 0
fi

PROMPT_SHA="$(sha256sum "$PROMPT_FILE" | cut -d' ' -f1)"

# --- dedup: already captured this cycle for this prompt? -------------------
if [[ -f "$MARKER" ]]; then
  marker_sha="$(cut -d' ' -f1 < "$MARKER")"
  marker_log="$(cut -d' ' -f2- < "$MARKER")"
  if [[ "$marker_sha" == "$PROMPT_SHA" ]]; then
    note="$(date -u +%Y-%m-%dT%H:%M:%SZ) skip: prompt ${PROMPT_SHA:0:12} already captured this cycle -> ${marker_log}"
    echo "$note" >> "$SKIP_LOG"
    log "dedup skip — first raw log this cycle: ${marker_log}"
    exit 0
  fi
  log "prompt changed since last capture (${marker_sha:0:12} -> ${PROMPT_SHA:0:12}) — re-capturing"
fi

# --- capture (non-blocking) -------------------------------------------------
RAW_LOG="${DIAG_DIR}/diagnostics_$(date -u +%Y%m%dT%H%M%SZ).log"

if ! command -v tillandsias >/dev/null 2>&1; then
  log "FINDING: tillandsias not on PATH — cannot run forge diagnostics prompt; annex non-blocking, continuing"
  exit 0
fi

log "capturing forge diagnostics -> $RAW_LOG"
# The forge is assumed already alive (piggy-back). Capture is best-effort: a
# launch/timeout/parse failure is a finding, never a caller failure.
if tillandsias . --opencode --diagnostics \
      --prompt "$(cat "$PROMPT_FILE")" 2>/dev/null \
      | tee "$RAW_LOG" >/dev/null; then
  if [[ -s "$RAW_LOG" ]]; then
    printf '%s %s\n' "$PROMPT_SHA" "$RAW_LOG" > "$MARKER"
    log "captured + marked ($MARKER)"
    # Distill into a durable plan/diagnostics summary (also non-blocking).
    if [[ -x "$DISTILL" ]]; then
      "$DISTILL" --latest "$RAW_LOG" || log "FINDING: distillation reported an issue (non-blocking)"
    fi
  else
    log "FINDING: diagnostics capture produced empty output — recorded, non-blocking"
  fi
else
  log "FINDING: forge diagnostics prompt did not complete — recorded, non-blocking"
fi

exit 0

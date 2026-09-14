#!/usr/bin/env bash
# @trace order:1185-9qx6, spec:ci-release
#
# record-ci-phase-result.sh — append ONE check-log record for a CI phase that
# ran OUTSIDE scripts/local-ci.sh.
#
# WHY THIS EXISTS (1185-9qx6). check-release-tier-freshness.sh answers "when was
# the RELEASE tier last exercised here" by reading
# target/convergence/check-logs.jsonl, and 1174-6r4k correctly narrowed it to
# FULL-tier runs: a run whose records say ci_phase `all`, or which between them
# cover pre-build AND post-build AND runtime. The reader was right and the
# WRITER could never satisfy it. `./build.sh --ci-full` drives only its
# pre-build gate through local-ci.sh (the only writer of that index); its
# post-build status smoke and runtime residual litmus run from build.sh through
# run-litmus-test.sh, which writes no record at all. Measured on macuahuitl
# 2026-09-14: a green ci-full, and all 245 entries the index had EVER held were
# ci_phase pre-build, so the guard read `never:release-tier` after the very run
# it exists to detect the absence of.
#
# So the fix is on the writer, and it is deliberately not "make ci-full claim a
# full tier". Each phase records what it actually did, with its real status, and
# the reader's own coverage rule decides. A `--phase pre-build` diagnostic still
# writes one pre-build record and still reads as not-a-release-tier-answer:
# 1174-6r4k's negative control is preserved BY CONSTRUCTION here, because
# nothing in this script can record a phase that did not run.
#
# The record shape is local-ci.sh's, field for field (ci_run_id, ci_phase,
# check_id, status, source_log, archived_log, sha256, duration_ms) — read that
# writer before changing anything here; the reader parses by substring and a
# renamed field matches nothing silently.
#
# Usage: record-ci-phase-result.sh <run-id> <phase> <check-id> <status> [log] [duration_ms]
#   status: pass | fail | skipped  (local-ci's vocabulary; the reader counts
#           `fail` as red and everything else as not-red)
#
# Exit codes: 0 recorded, 2 refused (bad arguments — nothing written),
#             3 could-not-run (no jq, unwritable index). 965-sxec grammar:
#             a non-zero here NEVER means the phase was bad, only that the
#             record could not be made.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "$#" -lt 4 ]; then
    echo "refused:record-ci-phase:usage: $(basename "$0") <run-id> <phase> <check-id> <status> [log] [duration_ms]" >&2
    exit 2
fi

RUN_ID="$1"; PHASE="$2"; CHECK_ID="$3"; STATUS="$4"; LOG="${5:-}"; DURATION_MS="${6:-0}"

# The run id is the correlation key the reader groups by; a malformed one is
# worse than no record, because it becomes an unparseable-timestamp run that
# reports could-not-run instead of falling back to the previous good answer.
case "$RUN_ID" in
    local-ci-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
    *) echo "refused:record-ci-phase:run-id '$RUN_ID' is not local-ci-YYYYMMDDTHHMMSSZ" >&2; exit 2 ;;
esac
case "$PHASE" in
    pre-build|build|post-build|runtime|install|all) ;;
    *) echo "refused:record-ci-phase:unknown phase '$PHASE'" >&2; exit 2 ;;
esac
case "$STATUS" in
    pass|fail|skipped) ;;
    *) echo "refused:record-ci-phase:status '$STATUS' is not pass|fail|skipped" >&2; exit 2 ;;
esac
case "$DURATION_MS" in
    ''|*[!0-9]*) DURATION_MS=0 ;;
esac

JQ="${JQ:-jq}"
command -v "$JQ" >/dev/null 2>&1 || { echo "could-not-run:record-ci-phase:no jq on PATH" >&2; exit 3; }

INDEX="${TILLANDSIAS_CHECK_LOG_INDEX:-$ROOT/target/convergence/check-logs.jsonl}"
mkdir -p "$(dirname "$INDEX")" 2>/dev/null || { echo "could-not-run:record-ci-phase:cannot create $(dirname "$INDEX")" >&2; exit 3; }

sha256_of() {
    [ -f "$1" ] || { printf '%s\n' ""; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else printf '%s\n' ""; fi
}

"$JQ" -nc \
    --arg ci_run_id "$RUN_ID" \
    --arg ci_phase "$PHASE" \
    --arg check_id "$CHECK_ID" \
    --arg status "$STATUS" \
    --arg source_log "$LOG" \
    --arg archived_log "$LOG" \
    --arg sha256 "$(sha256_of "$LOG")" \
    --argjson duration_ms "$DURATION_MS" \
    '{
      ci_run_id:$ci_run_id,
      ci_phase:$ci_phase,
      check_id:$check_id,
      status:$status,
      source_log:$source_log,
      archived_log:$archived_log,
      sha256:$sha256,
      duration_ms:$duration_ms
    }' >>"$INDEX" || { echo "could-not-run:record-ci-phase:append to $INDEX failed" >&2; exit 3; }

echo "ok:record-ci-phase:$RUN_ID:$PHASE:$STATUS"
exit 0

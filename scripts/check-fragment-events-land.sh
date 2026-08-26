#!/usr/bin/env bash
# check-fragment-events-land.sh — every event in the overlay must attach to a
# packet that exists.
#
# WHY THIS EXISTS. On 2026-08-23 a coordinator finding was filed against
# `macos-onboarding-defect-sweep`. The packet is
# `macos-host-onboarding-defect-sweep` — one word short. The fold refused to
# consume the fragment, correctly and loudly, on EVERY compaction for fourteen
# hours. Three separate cycle reports across two hosts read that refusal and
# classified it as a benign permanent refusal awaiting a tombstone. It was a
# real event attached to nothing, and no reader of 851-gpb5 ever saw it.
#
# A misfiled packet_id is SILENT DATA LOSS WEARING THE COSTUME OF TIDY
# BOOKKEEPING. Nothing is corrupted, nothing fails, the file is even preserved
# — and the record is invisible. That is precisely the failure class this
# project keeps naming, so it gets a gate rather than a habit.
#
# REUSES THE FOLD'S OWN JOIN rather than recomputing it. `compact --dry-run`
# already resolves every event's packet_id against the merged fold and reports
# what it could not place; a second implementation of "does this packet exist"
# is how two answers come to disagree. This asserts on that output and writes
# nothing.
#
# Grammar (one line on stdout):
#   ok:fragment-events-land:<n> fragment(s) checked
#   blocked:fragment-events-land:<n> event(s) attached to no packet
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/plan-binary-probe.sh"
if ! PLAN="$(ensure_fresh_plan_binary)"; then
    echo "blocked:fragment-events-land:no-fresh-plan-binary"
    exit 2
fi

n_frags="$(ls plan/index.d/*.yaml 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n_frags" = "0" ]; then
    echo "ok:fragment-events-land:0 fragment(s) checked"
    exit 0
fi

# --dry-run is REQUIRED here and is not a nicety: this is a gate, and a gate
# that mutates the thing it inspects is not one.
out="$("$PLAN" compact --dry-run 2>&1)"
orphans="$(printf '%s\n' "$out" | grep -c 'NO SUCH PACKET' || true)"

if [ "${orphans:-0}" -gt 0 ]; then
    echo "blocked:fragment-events-land:$orphans event(s) attached to no packet"
    printf '%s\n' "$out" | grep -B 1 'NO SUCH PACKET' >&2
    echo "  An event on a nonexistent packet is INVISIBLE, not merely unfolded:" >&2
    echo "  the fragment survives, compaction reports it forever, and no reader" >&2
    echo "  of any packet ever sees the record. Re-file it under the correct id." >&2
    exit 1
fi

echo "ok:fragment-events-land:$n_frags fragment(s) checked"

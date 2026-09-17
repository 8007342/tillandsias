#!/usr/bin/env bash
# test-loop-status-audit-reads-current-emitter.sh — order 1243-yiyq.
#
# WHY THIS EXISTS. loop-status-metrics-audit.sh anchored on the literal
# `skippable: candidates=`. cycle-metrics.sh later began emitting
# `skippable: window=7d candidates=`, and that one interposed field broke every
# match for twelve days. The audit kept printing a healthy-looking
# `rows=N stems=N` the whole time, because that check certifies ENUMERATION and
# not COMPREHENSION. A coordinator read the resulting all-NOT-PASTING output as
# a fleet behaviour, recorded it as a hazard, put it in a landed commit and a
# packet's context, and told a peer.
#
# The teeth are ARM 1 and ARM 4. Arm 1 pins that the audit can read what the
# emitter emits TODAY. Arm 4 is the part that keeps it true: it extracts the
# audit's own SHAPE and runs the REAL scripts/cycle-metrics.sh output against
# it, so the two files cannot drift apart again without this failing. A widened
# literal alone would have fixed today and bought nothing for next time.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# Overridable ONLY so the mutation control can aim this at a pre-fix copy
# without touching the tracked file. Production callers pass nothing.
AUDIT="${TILLANDSIAS_AUDIT_SCRIPT:-scripts/loop-status-metrics-audit.sh}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "ok:   $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*"; fail=$((fail+1)); }

mkcorpus() { d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }

# The CURRENT emitter's shape, written as data rather than copied from a guess.
CUR='skippable: window=7d candidates=98 floor_ms=2000 min_runs=5 top3=step:a:runs=1:avg_ms=2:fail_pct=0:saved_ms_upper=3 source=/x/y.jsonl'
OLD='skippable: candidates=77 floor_ms=2000 min_runs=5 top3=step:a:runs=1:avg_ms=2:fail_pct=0:saved_ms_upper=3 source=/x/y.jsonl'

# ---- ARM 1 (TEETH): the CURRENT emitter form is read as a paste.
d="$(mkcorpus a1)"
printf '## Cycle\n\n```\n%s\n```\n' "$CUR" > "$d/20260917t120000z-deadbeef-hostx.md"
out="$(TILLANDSIAS_LOOP_STATUS_DIR="$d" bash "$AUDIT" 2>/dev/null)"
case "$out" in
    *"hostx skippable:"*) ok "ARM 1 (teeth): an entry in the CURRENT emitter form reads as PASTING" ;;
    *"hostx NOT-PASTING"*) bad "ARM 1: the current emitter form reads NOT-PASTING — the anchor cannot see what cycle-metrics.sh emits" ;;
    *) bad "ARM 1: unexpected output: $out" ;;
esac

# ---- ARM 2: the OLD form still reads as a paste (no regression on history).
d="$(mkcorpus a2)"
printf '## Cycle\n\n```\n%s\n```\n' "$OLD" > "$d/20260901t120000z-deadbeef-hosty.md"
out="$(TILLANDSIAS_LOOP_STATUS_DIR="$d" bash "$AUDIT" 2>/dev/null)"
case "$out" in
    *"hosty skippable:"*) ok "ARM 2: the pre-drift form still reads as PASTING — the fix widened, it did not move" ;;
    *) bad "ARM 2: widening the anchor broke the historical form: $out" ;;
esac

# ---- ARM 3 (NEGATIVE CONTROL): a host genuinely not pasting is still caught.
# Without this, a fix that made the anchor match anything would pass arm 1.
d="$(mkcorpus a3)"
printf '## Cycle\n\nprose only, no machine block at all.\n' > "$d/20260917t120000z-deadbeef-hostz.md"
printf '## Cycle\n\n```\n%s\n```\n' "$CUR" > "$d/20260917t110000z-deadbeef-hostq.md"
out="$(TILLANDSIAS_LOOP_STATUS_DIR="$d" bash "$AUDIT" 2>/dev/null)"
case "$out" in
    *"hostz NOT-PASTING"*) ok "ARM 3 (negative control): a host with no metrics block is STILL reported NOT-PASTING" ;;
    *) bad "ARM 3: a genuinely non-pasting host was not caught — the anchor matches too much: $out" ;;
esac

# ---- ARM 4 (TEETH, and the one that keeps arm 1 true): the audit's OWN anchor
# must match the REAL emitter's output. This is the tie between the two files.
SHAPE_LINE="$(grep -m1 -E "^SHAPE=" "$AUDIT" || true)"
if [ -z "$SHAPE_LINE" ]; then
    bad "ARM 4: no SHAPE= assignment found in $AUDIT — the tie cannot be checked"
else
    eval "$SHAPE_LINE"
    emitted="$(bash scripts/cycle-metrics.sh 2>/dev/null | grep -m1 '^skippable: ' || true)"
    if [ -z "$emitted" ]; then
        echo "skip: ARM 4 — cycle-metrics.sh emitted no skippable line on this host; the tie is UNTESTED here, not satisfied"
    elif printf '%s' "$emitted" | grep -qE "$SHAPE"; then
        ok "ARM 4 (teeth): the audit's own SHAPE matches what cycle-metrics.sh emits RIGHT NOW"
    else
        bad "ARM 4: SHAPE does not match the live emitter — they have drifted apart again. emitted: ${emitted:0:80}"
    fi
fi

# ---- ARM 5: prose ABOUT a skippable line must not satisfy the anchor.
# Defect 2 in the audit's own header; the widening must not reintroduce it.
d="$(mkcorpus a5)"
printf '## Cycle\n\nI looked at the skippable: candidates in the report and thought about them.\n' > "$d/20260917t120000z-deadbeef-hostp.md"
out="$(TILLANDSIAS_LOOP_STATUS_DIR="$d" bash "$AUDIT" 2>/dev/null)"
case "$out" in
    *"hostp NOT-PASTING"*) ok "ARM 5: prose mentioning a skippable line does NOT count as a paste" ;;
    *) bad "ARM 5: prose satisfied the anchor — the widening reintroduced the header's defect 2: $out" ;;
esac

# ---- ARM 6: a corpus where NOTHING parses refuses with a drift verdict,
# not with a fleet-behaviour claim. "No host is pasting" and "I cannot read any
# host" send a reader to opposite places.
d="$(mkcorpus a6)"
printf '## Cycle\n\nno machine block.\n' > "$d/20260917t120000z-deadbeef-hostr.md"
printf '## Cycle\n\nnone here either.\n' > "$d/20260917t110000z-deadbeef-hosts.md"
err="$(TILLANDSIAS_LOOP_STATUS_DIR="$d" bash "$AUDIT" 2>&1 >/dev/null)"; rc=$?
if printf '%s' "$err" | grep -q "violation:anchor-matches-nothing"; then
    ok "ARM 6: a corpus with zero readable lines refuses with a FORMAT-DRIFT verdict, not a host verdict"
else
    bad "ARM 6: zero readable lines produced no drift verdict — every host reads NOT-PASTING and the parser is never suspected"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "ok:loop-status-audit-reads-current-emitter:$pass"
    echo "PASS: loop-status-audit-reads-current-emitter $pass/$pass (1243-yiyq)"
    exit 0
fi
echo "violation:loop-status-audit-anchor:$fail arm(s) failed"
exit 1

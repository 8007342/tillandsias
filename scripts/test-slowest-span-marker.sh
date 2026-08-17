#!/usr/bin/env bash
# Order 785-ibu9 — the slowest= provenance marker.
# A build-span record is wall clock between banners, not the named step's own
# cost, so the one number a cycle reads first must say which it is.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0

printf '{"step":"step:coarse","phase":"build-span","duration_ms":9000}\n{"step":"step:fast","phase":"build","duration_ms":5}\n' > "$T/span.jsonl"
out="$(TILLANDSIAS_TIMING_LOG="$T/span.jsonl" bash "$ROOT/scripts/cycle-metrics.sh" --experts-only 2>/dev/null | grep '^timing:')"
case "$out" in
    *"slowest=step:coarse~span:9000"*) echo "ok: a span-provenance slowest is marked ~span" ;;
    *) echo "FAIL: span slowest not marked — $out"; fail=1 ;;
esac

printf '{"step":"step:real","phase":"build","duration_ms":7000}\n' > "$T/work.jsonl"
out="$(TILLANDSIAS_TIMING_LOG="$T/work.jsonl" bash "$ROOT/scripts/cycle-metrics.sh" --experts-only 2>/dev/null | grep '^timing:')"
case "$out" in
    *"slowest=step:real:7000"*) echo "ok: an attributable slowest carries no marker" ;;
    *) echo "FAIL: measured slowest wrongly marked — $out"; fail=1 ;;
esac

# Pre-785 logs carry no phase field at all and must keep working unmarked.
printf '{"step":"step:legacy","duration_ms":4000}\n' > "$T/legacy.jsonl"
out="$(TILLANDSIAS_TIMING_LOG="$T/legacy.jsonl" bash "$ROOT/scripts/cycle-metrics.sh" --experts-only 2>/dev/null | grep '^timing:')"
case "$out" in
    *"slowest=step:legacy:4000"*) echo "ok: pre-785 records without a phase field are unaffected" ;;
    *) echo "FAIL: legacy record changed shape — $out"; fail=1 ;;
esac

[ "$fail" -eq 0 ] && { echo "ok:slowest-span-marker-fixture:3"; exit 0; }
echo "fail: slowest-span-marker scenarios failed"; exit 1

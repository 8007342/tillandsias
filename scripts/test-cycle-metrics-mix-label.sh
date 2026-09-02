#!/usr/bin/env bash
# ORDER 890-nkdz, rule 1 (FORCED-ONLY for cross-host gate timings). The
# `timing:` line must carry `build_check_mix=mixed:forced=N,memoised=M` whenever
# the contributing log holds ANY memoised gate run, and must carry NO such label
# only when every run was forced. Two arms against synthetic timing logs; the
# mean itself must exclude memoised records in both.
#
# This leg was RED against the pre-890 reporter (it emitted no label for a
# mixed log) and green after — a leg that passes either way would be the
# threshold-of-zero mistake the packet's own review rule names.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/cycle-metrics-mix.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
check() { if [ "$1" = ok ]; then pass=$((pass+1)); echo "ok   $2"; else fail=$((fail+1)); echo "FAIL $2"; fi; }

printf '{"step":"build-check","duration_ms":64000,"phase":"check"}\n{"step":"build-check-memoized","duration_ms":400,"phase":"check"}\n{"step":"build-check","duration_ms":66000,"phase":"check"}\n' > "$W/mixed.jsonl"
line="$(TILLANDSIAS_TIMING_LOG="$W/mixed.jsonl" bash "$ROOT/scripts/cycle-metrics.sh" 2>/dev/null | grep '^timing:')"
case "$line" in
    *"build_check_ms_avg=65000 build_check_mix=mixed:forced=2,memoised=1 "*) check ok "mixed log: labelled, mean excludes the memoised run ($(printf '%s' "$line" | grep -oE 'build_check_[a-z_]+=[^ ]+' | tr '\n' ' '))" ;;
    *) check FAIL "mixed log: expected label mixed:forced=2,memoised=1 and mean 65000; got: ${line:-<no timing line>}" ;;
esac

printf '{"step":"build-check","duration_ms":64000,"phase":"check"}\n{"step":"build-check","duration_ms":66000,"phase":"check"}\n' > "$W/forced.jsonl"
line="$(TILLANDSIAS_TIMING_LOG="$W/forced.jsonl" bash "$ROOT/scripts/cycle-metrics.sh" 2>/dev/null | grep '^timing:')"
case "$line" in
    *"build_check_mix="*) check FAIL "forced-only log must carry no label; got: $line" ;;
    *"build_check_ms_avg=65000 "*) check ok "forced-only log: no label, mean 65000" ;;
    *) check FAIL "forced-only log: unexpected line: ${line:-<no timing line>}" ;;
esac

total=$((pass+fail))
if [ $fail -eq 0 ]; then echo "PASS: build_check_mix label ${pass}/${total} (890-nkdz)"; exit 0; fi
echo "FAIL: build_check_mix label ${fail}/${total} red (890-nkdz)"; exit 1

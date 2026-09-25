#!/usr/bin/env bash
# @trace order:1242-4x53, spec:methodology-accountability
#
# WHY THIS FIELD EXISTS. On 2026-09-17 both non-timeout failures in a red
# release tier passed on re-run, in the host regime AND inside the builder
# toolbox. The timing log records ts/host/step/phase/duration_ms/exit, so a red
# that reproduces and a red that does not are the same record, and the fleet's
# 25-29% gate failure rate cannot be split into regressions and
# non-determinism. This fixture pins the SCHEMA half: `--emit-timing` carries
# `reproduced=yes|no` when a caller knows the answer, and writes no key at all
# when it does not.
#
# THE ABSENT-CASE RULE: absent means "not re-run" or "written before the field
# existed", NEVER "did not reproduce". So a value outside yes|no is dropped
# rather than coerced — coercing to "no" would manufacture exactly the
# non-determinism evidence this row exists to measure honestly.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
ROOT="$PWD"

pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

JQ="$(command -v jq 2>/dev/null || true)"
if [ -z "$JQ" ]; then
    printf 'skip:timing-record-reproduced:no-jq — every arm reads records with it\n'
    exit 0
fi

# emit <log> [reproduced-token]  — one record through the real emitter
emit() {
    env TILLANDSIAS_TIMING_LOG="$1" \
        bash "$ROOT/scripts/cycle-metrics.sh" --emit-timing \
        step=arm phase=test duration_ms=5 exit=1 ${2:+"$2"} >/dev/null 2>&1
}
field() { "$JQ" -r 'if has("reproduced") then .reproduced else "ABSENT" end' < "$1" 2>/dev/null | tail -1; }

# ARM 1 — a failure that reproduced is recorded as such.
emit "$TMP/a1.jsonl" reproduced=yes
[ "$(field "$TMP/a1.jsonl")" = yes ] && ok "reproduced=yes is recorded" \
    || bad "reproduced=yes not recorded: $(cat "$TMP/a1.jsonl" 2>/dev/null)"

# ARM 2 — a failure that did not reproduce is recorded as such.
emit "$TMP/a2.jsonl" reproduced=no
[ "$(field "$TMP/a2.jsonl")" = no ] && ok "reproduced=no is recorded" \
    || bad "reproduced=no not recorded: $(cat "$TMP/a2.jsonl" 2>/dev/null)"

# ARM 3 — no token: no key. Absent must stay distinguishable from "no".
emit "$TMP/a3.jsonl"
[ "$(field "$TMP/a3.jsonl")" = ABSENT ] && ok "no token writes no reproduced key" \
    || bad "absent token wrote a key: $(cat "$TMP/a3.jsonl" 2>/dev/null)"

# ARM 4 — a value outside yes|no is dropped, not coerced to either answer.
emit "$TMP/a4.jsonl" 'reproduced=maybe"x'
if [ "$(field "$TMP/a4.jsonl")" = ABSENT ] && "$JQ" -e . < "$TMP/a4.jsonl" >/dev/null 2>&1; then
    ok "an invalid value writes no key and the row stays valid JSON"
else
    bad "invalid value leaked or broke the row: $(cat "$TMP/a4.jsonl" 2>/dev/null)"
fi

# ARM 5 — the existing fields keep their order, so positional readers are inert.
keys="$("$JQ" -r 'keys_unsorted | .[0:6] | join(",")' < "$TMP/a1.jsonl" 2>/dev/null)"
[ "$keys" = "ts,host,step,phase,duration_ms,exit" ] && ok "leading field order unchanged" \
    || bad "leading field order moved: $keys"

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'ok:timing-record-reproduced:%d/%d\n' "$pass" "$total"
else
    printf 'refused:timing-record-reproduced:%d/%d\n' "$pass" "$total"
    exit 1
fi

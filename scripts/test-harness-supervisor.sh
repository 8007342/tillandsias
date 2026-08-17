#!/usr/bin/env bash
# test-harness-supervisor.sh — hermetic fixtures for images/default/
# harness-supervisor.sh (order 767-nkkq). No podman, no network; every
# scenario runs the real script on this host with a throwaway evidence dir.
#
# Pinned properties:
#   1. clean-exit control: rc 0 passes through with ZERO wrapper output;
#   2. ordinary failure passes through untouched (rc preserved, silent);
#   3. a fatal signal yields the named verdict line on stdout AND stderr,
#      a persisted evidence file carrying signal/rc/harness/pointer fields,
#      the child ran EXACTLY ONCE (no respawn), and the rc is preserved;
#   4. SIGTERM to the supervisor is forwarded to the child (bounded exit);
#   5. missing args refuse with usage on rc 2.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUP="$ROOT/images/default/harness-supervisor.sh"
fail=0

T="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$T'" EXIT

# 1. clean control
out="$(TILLANDSIAS_CRASH_EVIDENCE_DIR="$T/ev1" bash "$SUP" testh true 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -d "$T/ev1" ]; then
    echo "ok: clean exit passes through silently (rc=0, no output, no evidence dir)"
else
    echo "FIXTURE-FAIL: clean control rc=$rc out='$out'"; fail=1
fi

# 2. ordinary failure passthrough
out="$(TILLANDSIAS_CRASH_EVIDENCE_DIR="$T/ev2" bash "$SUP" testh bash -c 'exit 3' 2>&1)"
rc=$?
if [ "$rc" -eq 3 ] && [ -z "$out" ]; then
    echo "ok: ordinary failure passes through untouched (rc=3, silent)"
else
    echo "FIXTURE-FAIL: ordinary failure rc=$rc out='$out'"; fail=1
fi

# 3. crash: verdict, evidence, exactly-once, rc preserved
marker="$T/launch-count"
: > "$marker"
stdout_f="$T/crash.out"; stderr_f="$T/crash.err"
TILLANDSIAS_CRASH_EVIDENCE_DIR="$T/ev3" TILLANDSIAS_CRASH_LAST_OUTPUT="$T/lifecycle.log" \
    bash "$SUP" testh bash -c "echo x >> '$marker'; kill -SEGV \$\$" \
    >"$stdout_f" 2>"$stderr_f"
rc=$?
verdict='fail:harness-crashed:harness=testh:signal=11:rc=139'
launches="$(wc -l < "$marker" | tr -d ' ')"
report="$(ls "$T/ev3"/crash-testh-*.txt 2>/dev/null | head -1)"
if [ "$rc" -eq 139 ] && grep -qxF "$verdict" "$stdout_f" && grep -qxF "$verdict" "$stderr_f" \
   && [ "$launches" = "1" ] && [ -n "$report" ] \
   && grep -q '^signal: 11$' "$report" && grep -q '^rc: 139$' "$report" \
   && grep -qF "last_output_pointer: $T/lifecycle.log" "$report" \
   && grep -q 'no restart attempted' "$report"; then
    echo "ok: SIGSEGV -> named verdict on both streams, evidence persisted, exactly one launch, rc=139 preserved"
else
    echo "FIXTURE-FAIL: crash scenario rc=$rc launches=$launches report=$report"
    sed -n '1,3p' "$stdout_f" 2>/dev/null; fail=1
fi

# 4. SIGTERM forwarded to the child, bounded — and an ORDERED shutdown must
#    NOT read as a crash (no verdict output; `podman stop` semantics).
term_out="$T/term.out"
TILLANDSIAS_CRASH_EVIDENCE_DIR="$T/ev4" bash "$SUP" testh sleep 30 >"$term_out" 2>&1 &
sup_pid=$!
sleep 0.5
kill -TERM "$sup_pid" 2>/dev/null
waited=0
while kill -0 "$sup_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1; waited=$((waited + 1))
done
if ! kill -0 "$sup_pid" 2>/dev/null && ! grep -q 'harness-crashed' "$term_out" && [ ! -d "$T/ev4" ]; then
    echo "ok: SIGTERM forwarded, bounded exit, and an ordered shutdown emits NO crash verdict"
else
    echo "FIXTURE-FAIL: SIGTERM handling (alive=$(kill -0 "$sup_pid" 2>/dev/null && echo yes || echo no) out='$(cat "$term_out" 2>/dev/null)')"
    kill -KILL "$sup_pid" 2>/dev/null; fail=1
fi
wait "$sup_pid" 2>/dev/null || true

# 4b. an EXTERNAL kill of the child alone (supervisor never signaled — the
#     OOM-killer shape) still verdicts loudly.
ext_out="$T/ext.out"
TILLANDSIAS_CRASH_EVIDENCE_DIR="$T/ev4b" bash "$SUP" testh sleep 30 >"$ext_out" 2>&1 &
sup_pid=$!
sleep 0.5
child_pid="$(pgrep -P "$sup_pid" -f 'sleep 30' | head -1)"
# The supervisor's child is bash-free here (direct sleep); fall back to any child.
[ -z "$child_pid" ] && child_pid="$(pgrep -P "$sup_pid" | head -1)"
kill -KILL "$child_pid" 2>/dev/null
wait "$sup_pid" 2>/dev/null
rc=$?
if [ "$rc" -eq 137 ] && grep -q 'fail:harness-crashed:harness=testh:signal=9:rc=137' "$ext_out"; then
    echo "ok: external SIGKILL of the child alone still verdicts loudly (rc=137)"
else
    echo "FIXTURE-FAIL: external-kill scenario rc=$rc out='$(cat "$ext_out" 2>/dev/null)'"; fail=1
fi

# 5. usage refusal
bash "$SUP" only-one-arg >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then
    echo "ok: missing command refuses with rc=2"
else
    echo "FIXTURE-FAIL: usage refusal rc=$rc"; fail=1
fi

# 6. image + entrypoint wiring, WITH a negative control proving the matcher
#    can fail (634-39ik: a pin without falsifiability is a tautology).
oc_entry="$ROOT/images/default/entrypoint-forge-opencode.sh"
cx_entry="$ROOT/images/default/entrypoint-forge-codex.sh"
cf="$ROOT/images/default/Containerfile"
wired_oc="$(grep -cF 'exec /usr/local/bin/harness-supervisor opencode' "$oc_entry")"
wired_cx="$(grep -cF 'exec /usr/local/bin/harness-supervisor codex' "$cx_entry")"
copied="$(grep -cF '/usr/local/bin/harness-supervisor' "$cf")"
interactive_direct="$(grep -cF 'exec "$OC_BIN" "$@"' "$oc_entry")"
# negative control: strip the supervisor lines from a copy; the same matchers
# must then FAIL, or this scenario could never catch an unwiring.
stripped="$T/entry-stripped.sh"
grep -vF 'harness-supervisor' "$oc_entry" > "$stripped"
neg="$(grep -cF 'exec /usr/local/bin/harness-supervisor opencode' "$stripped")"
if [ "$wired_oc" = "2" ] && [ "$wired_cx" = "1" ] && [ "$copied" -ge 2 ] \
   && [ "$interactive_direct" = "1" ] && [ "$neg" = "0" ]; then
    echo "ok: wiring — 2 opencode + 1 codex supervised lanes, image COPY+chmod, interactive lane direct-exec; negative control red on a stripped copy"
else
    echo "FIXTURE-FAIL: wiring oc=$wired_oc cx=$wired_cx copied=$copied interactive=$interactive_direct neg=$neg"; fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "ok: all harness-supervisor scenarios passed"
    exit 0
fi
echo "fail: harness-supervisor fixture scenarios failed"
exit 1

#!/usr/bin/env bash
# =============================================================================
# harness-supervisor.sh — minimal PID-1 crash supervision for forge harnesses
# (order 767-nkkq; disposition chosen by 604-vmcg's forensics).
#
#   harness-supervisor <harness-name> <command> [args...]
#
# Today the agent harness is exec'd as PID 1, so a runtime fault (the
# build-id-verified Bun/JSC SIGSEGV class: 2026-08-03 + 2026-08-10 x86_64,
# 2026-07-27 arm64) kills the container with status 139 and NOTHING in the
# lane says so — only host-side systemd-coredump noticed, and in-flight work
# died silently (the 741-3y48 class, one level down).
#
# This wrapper stays PID 1 itself, runs the harness as a child, and:
#   * clean exit (rc < 128): passes the exit code through UNTOUCHED, with
#     zero wrapper output — the happy path is byte-identical to before;
#   * fatal signal (rc >= 128): emits ONE loud, machine-grepable line
#         fail:harness-crashed:harness=<name>:signal=<n>:rc=<rc>
#     on BOTH stdout and stderr (launchers capture different streams),
#     persists a crash-evidence file, and exits with the same rc so the
#     container status still tells the truth;
#   * NEVER restarts the agent. A crashed drain cycle must not re-run its
#     prompt unattended (packet constraint; the order-417 bounded-keepalive
#     precedent is about liveness probes, not agent re-runs — this is a
#     hard zero-restart policy, stricter on purpose);
#   * forwards SIGTERM/SIGINT to the child so `podman stop` semantics are
#     unchanged, and keeps bash's default PID-1 child reaping.
#
# Evidence surface (741-3y48 rules — the checkout is ephemeral): the loud
# stdout/stderr line IS the primary durable channel (every launcher — the
# litmus tee, the host lane runner, an attached operator — captures it), and
# a copy of the crash report is written to $TILLANDSIAS_CRASH_EVIDENCE_DIR
# (default /tmp/forge-crash-evidence; a fixture override and, in-forge, a
# surface the lifecycle log and any later harvest can read). The report
# names the signal, rc, harness, timestamp, and a last-output pointer
# (TILLANDSIAS_CRASH_LAST_OUTPUT, when the caller has one to offer).
# =============================================================================
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: harness-supervisor <harness-name> <command> [args...]" >&2
    exit 2
fi

HARNESS_NAME="$1"
shift

EVIDENCE_DIR="${TILLANDSIAS_CRASH_EVIDENCE_DIR:-/tmp/forge-crash-evidence}"

child_pid=0
# A signal WE forwarded is an ordered shutdown (`podman stop`, operator ^C) —
# the child dying of it is expected and must NOT read as a crash, or every
# graceful stop would emit a false crashed verdict. A fatal signal the
# supervisor never relayed (SEGV, ABRT, OOM-killer's KILL) stays loud.
forwarded_shutdown=0
forward() { # <signal>
    forwarded_shutdown=1
    [ "$child_pid" -gt 0 ] && kill -s "$1" "$child_pid" 2>/dev/null
}
trap 'forward TERM' TERM
trap 'forward INT' INT

"$@" &
child_pid=$!

# wait is interrupted by trapped signals; loop until the child truly exits.
rc=127
while :; do
    if wait "$child_pid"; then
        rc=0
        break
    else
        rc=$?
        # If the child is still alive, the wait was interrupted by a trap —
        # keep waiting. If it is gone, rc is the child's real status.
        kill -0 "$child_pid" 2>/dev/null || break
    fi
done

if [ "$rc" -lt 128 ]; then
    # Clean (or ordinary-failure) exit: pass through untouched, say nothing.
    exit "$rc"
fi

sig=$((rc - 128))

# Ordered shutdown: we relayed TERM/INT ourselves and the child died of a
# stop-shaped signal — that is `podman stop` semantics, not a crash.
if [ "$forwarded_shutdown" -eq 1 ] && { [ "$sig" -eq 15 ] || [ "$sig" -eq 2 ] || [ "$sig" -eq 1 ]; }; then
    exit "$rc"
fi
ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
verdict="fail:harness-crashed:harness=${HARNESS_NAME}:signal=${sig}:rc=${rc}"

echo "$verdict"
echo "$verdict" >&2

mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
report="$EVIDENCE_DIR/crash-${HARNESS_NAME}-${ts}.txt"
{
    echo "verdict: $verdict"
    echo "harness: $HARNESS_NAME"
    echo "signal: $sig"
    echo "rc: $rc"
    echo "ts: $ts"
    echo "cmd: $*"
    echo "last_output_pointer: ${TILLANDSIAS_CRASH_LAST_OUTPUT:-<none-provided>}"
    echo "supervision: 767-nkkq — no restart attempted (by design); container exits rc=$rc"
    echo "forensics: host-side coredump (if any) via coredumpctl; preserved incidents in ~/claudia/tillandsias-forensics/604-vmcg/ on the host"
} > "$report" 2>/dev/null || true

exit "$rc"

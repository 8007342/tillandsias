#!/usr/bin/env bash
# @trace order:1134-u934, spec:tillandsias-vault
#
# test-vault-shutdown-forwards-sigterm.sh — the closure 1134-u934 named.
#
# WHAT IT ASSERTS, against a LIVE container rather than against the script's
# text: `podman stop -t <grace> tillandsias-vault` returns in well under the
# grace AND the container's ExitCode is 0. Both halves matter and neither one
# alone is the bug:
#
#   * elapsed alone would pass a container that exits fast for a bad reason;
#   * ExitCode alone would pass a container that takes the full grace and is
#     then reported 0 by some future podman.
#
# WHY NOT A UNIT TEST OF THE SCRIPT. The defect 1134-u934 filed was a PID-1
# shell that traps nothing, plus `$!` after a backgrounded PIPELINE holding
# TEE's pid instead of vault's. Both are properties of the PROCESS TREE at
# runtime; a text fixture that greps for `trap` would have passed the wrong
# fix — a trap forwarding to tee — which is the exact trap the packet warned
# about ("worse than no trap, because it looks fixed").
#
# MEASURED RED before the fix, on pirria, against
# localhost/tillandsias-vault:sha256-be8031931d (built from the pre-fix
# entrypoint): elapsed 30s, ExitCode 137, OOMKilled false. See the run log
# quoted in the closure evidence of 1134-u934.
#
# COULD-NOT-RUN, not pass: this needs a provisioned enclave. A host that has
# never run `tillandsias --init` has no `tillandsias-vault` container, and
# exit 3 (the 923-ws3r channel, as used by archive-plan-packets.sh) says so
# with a stable token rather than printing ok: over an assertion that never
# executed — the 1024-c3h3 could-not-run-reported-as-clean shape.
#
# Exit: 0 pass | 1 assertion failed | 3 could-not-run (no podman / no container)
set -uo pipefail

CONTAINER="${TILLANDSIAS_VAULT_CONTAINER:-tillandsias-vault}"
GRACE="${TILLANDSIAS_VAULT_STOP_GRACE:-30}"
# The bar. A forwarded SIGTERM lets vault seal and exit in about a second; the
# unfixed path takes the whole grace. Half the grace separates those two
# regimes by a wide margin without pinning a number this host's speed sets.
BUDGET=$(( GRACE / 2 ))

command -v podman >/dev/null 2>&1 || {
    echo "could-not-run:no-podman (1134-u934)"; exit 3; }

podman container exists "$CONTAINER" 2>/dev/null || {
    echo "could-not-run:no-vault-container:$CONTAINER (1134-u934) — run \`tillandsias --init\` first"; exit 3; }

WAS_RUNNING=0
if [ "$(podman inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]; then
    WAS_RUNNING=1
else
    echo "test: $CONTAINER is not running — starting it for the measurement"
    podman start "$CONTAINER" >/dev/null 2>&1 || {
        echo "could-not-run:vault-would-not-start (1134-u934)"; exit 3; }
fi

# Let it reach the state whose shutdown is under test. An unsealed, serving
# vault is the case the packet measured; stopping one that is still booting
# measures the boot path instead.
i=0
until [ "$(podman inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "could-not-run:vault-never-became-healthy-in-60s (1134-u934)"
        [ "$WAS_RUNNING" -eq 1 ] || podman stop -t 5 "$CONTAINER" >/dev/null 2>&1
        exit 3
    fi
    sleep 1
done

echo "test: stopping $CONTAINER with -t $GRACE (budget: under ${BUDGET}s, exit 0)"
_t0="$(date +%s)"
podman stop -t "$GRACE" "$CONTAINER" >/dev/null 2>&1
_t1="$(date +%s)"
ELAPSED=$(( _t1 - _t0 ))

EXIT_CODE="$(podman inspect "$CONTAINER" --format '{{.State.ExitCode}}' 2>/dev/null)"
OOM="$(podman inspect "$CONTAINER" --format '{{.State.OOMKilled}}' 2>/dev/null)"
echo "measured: elapsed=${ELAPSED}s exit_code=${EXIT_CODE} oom_killed=${OOM} grace=${GRACE}s"

# Put the host back the way it was found. This runs before the verdict on
# purpose: a red assertion must not also leave the enclave down.
if [ "$WAS_RUNNING" -eq 1 ]; then
    podman start "$CONTAINER" >/dev/null 2>&1 || \
        echo "warn: could not restart $CONTAINER after the measurement" >&2
fi

rc=0
if [ "$ELAPSED" -ge "$BUDGET" ]; then
    echo "bad: stop took ${ELAPSED}s of a ${GRACE}s grace — SIGTERM is not reaching vault (1134-u934)"
    rc=1
fi
if [ "$EXIT_CODE" != "0" ]; then
    if [ "$EXIT_CODE" = "137" ]; then
        echo "bad: ExitCode 137 — the container was SIGKILLed at the end of the grace (1134-u934)"
    else
        echo "bad: ExitCode $EXIT_CODE, want 0 (1134-u934)"
    fi
    rc=1
fi

if [ "$rc" -eq 0 ]; then
    echo "ok: vault stopped in ${ELAPSED}s (< ${BUDGET}s) with exit 0 — SIGTERM is forwarded"
else
    echo "FAIL: vault's shutdown path is the 1134-u934 defect"
fi
exit "$rc"

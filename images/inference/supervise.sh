#!/bin/sh
# @trace spec:inference-container, order:1859-v5iv
#
# supervise.sh — the inference entrypoint's last step: wait on the engine, and
# on SIGTERM or SIGINT pass the signal on to the engine and every other
# background job, then exit with the engine's status.
#
# WHY. The entrypoint is PID 1 in its container. The kernel delivers no signal
# to PID 1 that PID 1 has not installed a handler for, so the old final line,
# `wait $OLLAMA_PID`, ignored the SIGTERM from `podman stop`: the container sat
# out the whole stop timeout and was SIGKILLed with exit 137 (measured on
# macuahuitl 2026-10-24). Outside PID 1 the same line has the opposite fault:
# the shell dies on SIGTERM and leaves ollama and the background pulls running.
#
# HOW. A trap only records the signal; `wait` returns early when a trapped
# signal arrives, and the loop then forwards SIGTERM to every job (`jobs -p`
# includes the engine), waits for them, and exits with the engine's status.
# An engine that ends on its own exits the container with its own status.
#
# Sourced by entrypoint.sh; runnable with a stub engine for the fixture
# (scripts/lua/test-inference-supervise.lua).

tillandsias_supervise() {
    _tsv_main=$1
    _tsv_sig=
    trap '_tsv_sig=TERM' TERM
    trap '_tsv_sig=INT' INT
    while :; do
        # Checked BEFORE each wait as well as after it: a signal that lands
        # between the trap and the first wait must not wait out the engine.
        if [ -n "$_tsv_sig" ]; then
            echo "[inference] SIG$_tsv_sig received: stopping the engine and background jobs" >&2
            # shellcheck disable=SC2046 # one pid per word
            kill -TERM $(jobs -p) 2>/dev/null
            wait "$_tsv_main"
            _tsv_rc=$?
            wait
            exit "$_tsv_rc"
        fi
        wait "$_tsv_main"
        _tsv_rc=$?
        [ -n "$_tsv_sig" ] && continue
        exit "$_tsv_rc"
    done
}

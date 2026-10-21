#!/bin/sh
# @trace order:1804-sccl
#
# sccache-wrapper.sh — RUSTC_WRAPPER shim. Usage by cargo: sccache-wrapper.sh <rustc> <args...>
#
# WHY. sccache starts its server through a unix socket created under $TMPDIR,
# and a socket path must fit sockaddr_un (108 bytes). The preflight door runs
# each guard with TMPDIR=$TMPDIR/pf-guard.XXXXXX, and an agent session's
# TMPDIR alone is ~100 bytes, so any guard that hits a DEAD server (first use,
# or after the idle timeout) dies with
#     sccache: error: path must be shorter than SUN_LEN        (rc=2)
# on cargo's first `rustc -vV` probe, i.e. "sccache: encountered fatal error"
# in land run 184 (#590, a-claim-names-a-workstation ARM 6). Whether it fires
# depends on whether some earlier guard left a server up, hence intermittent.
# Fix: start/talk to sccache with a short TMPDIR. A cache must never red a gate,
# so if sccache itself still fails to run, fall back to the bare compiler.
sc="${TILLANDSIAS_SCCACHE_BIN:-$(command -v sccache 2>/dev/null)}"
if [ -z "$sc" ]; then exec "$@"; fi
case "${TMPDIR:-}" in ''|/tmp|/tmp/) ;; *) [ "${#TMPDIR}" -le 40 ] || TMPDIR=/tmp ;; esac
export TMPDIR="${TMPDIR:-/tmp}"
"$sc" "$@"; rc=$?
# rc 2 / 254 with no compiler involved = sccache's own startup failure (an
# unsupported-compiler call still runs the compiler and returns its rc).
if [ "$rc" -eq 2 ] || [ "$rc" -eq 254 ]; then
    if ! "$sc" --show-stats >/dev/null 2>&1; then
        echo "sccache-wrapper: sccache unavailable (rc=$rc); running the compiler directly" >&2
        exec "$@"
    fi
fi
exit "$rc"

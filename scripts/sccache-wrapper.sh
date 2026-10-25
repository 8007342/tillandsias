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
#
# @trace order:1812-bztj — and never a TMPDIR the caller will delete. The
# server is a long-lived SHARED daemon that inherits TMPDIR from whichever call
# starts it; the door's pf-guard.XXXXXX dir is short enough to have been kept
# here, so a guard started the server, the door removed the dir, and every
# later compile on the host failed "Failed to create temp dir" until someone
# stopped the server by hand (macuahuitl 2026-10-22, two preflight guards red).
# /tmp outlives every caller, so the daemon always gets /tmp.
sc="${TILLANDSIAS_SCCACHE_BIN:-$(command -v sccache 2>/dev/null)}"
if [ -z "$sc" ]; then exec "$@"; fi
export TMPDIR=/tmp
# @trace order:1841-7pvs — a HUNG server never exits, so the rc test below never
# fires (2026-10-23: a gate sat 46 min, three rustc clients in wait_woken).
# sccache 0.18 has no client-side request-timeout knob (only SCCACHE_IDLE_TIMEOUT
# and SCCACHE_STARTUP_NOTIFY), and bounding the compile itself would kill a slow
# but healthy rustc mid-write, which corrupted the incremental cache. So: probe
# the server with a short bound; only a probe TIMEOUT (rc 124) means hung, and
# then run the bare compiler. A healthy server gets the real compile, unbounded.
# Without coreutils timeout (stock darwin) the probe is skipped (old behaviour).
if command -v timeout >/dev/null 2>&1; then
    timeout "${TILLANDSIAS_SCCACHE_PROBE_SECS:-10}" "$sc" --show-stats >/dev/null 2>&1; prc=$?
    if [ "$prc" -eq 124 ]; then
        echo "sccache-wrapper: sccache server unresponsive; running the compiler directly" >&2
        exec "$@"
    fi
fi
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

#!/usr/bin/env bash
# @trace order:2118-77ew, spec:ci-release
#
# gate-tmpdir.sh — a gate leaves nothing behind in /tmp. SOURCE this.
#
# MEASURED on macuahuitl 2026-11-20 (operator P2, landing-pipeline redesign):
# /tmp (tmpfs) held 22 of 32 GB in about 16k entries, 7.7k of them
# tillandsias-test-cache-* (crates/tillandsias-headless test_cache_root makes
# about 58 per test process and never removes them), plus fixture homes and a
# stale podman store. Build-check had drifted from 28-31 to 50-53 min with
# every step proportionally slower, and a full tmpfs pushes the host into swap.
#
# Fixing leakers one by one never converges: each new fixture is a new leak.
# So the gate owns ONE private TMPDIR for its whole run and removes it when the
# run ends, whatever the outcome. Everything that honours TMPDIR (Rust
# std::env::temp_dir, mktemp, most fixtures) lands inside it. A path short
# enough for unix sockets: <parent TMPDIR or /tmp>/tg.XXXXXX.
#
# gate_tmpdir_run <cmd...>   (or, executed: scripts/gate-tmpdir.sh run <cmd...>)
#   Runs cmd as a CHILD with TMPDIR (and TILLANDSIAS_GATE_TMPDIR) set to a
#   fresh private dir, forwards TERM/INT/HUP to it, waits, removes the dir,
#   and returns cmd's exit code. stdin is passed through. When
#   TILLANDSIAS_GATE_TMPDIR is already set (the child itself, or a nested
#   gate), it just runs cmd in place: one dir per outermost gate.
#   TILLANDSIAS_GATE_TMPDIR_OFF=1 runs cmd in place without a private dir.
#   If the dir cannot be created the gate still runs, in place, and says so:
#   a cleanup aid never stops a gate.

gate_tmpdir_run() {
    if [ -n "${TILLANDSIAS_GATE_TMPDIR:-}" ] || [ "${TILLANDSIAS_GATE_TMPDIR_OFF:-0}" = 1 ]; then
        local rc0=0; "$@" || rc0=$?
        return "$rc0"
    fi
    local parent="${TMPDIR:-/tmp}" dir
    if ! dir="$(mktemp -d "$parent/tg.XXXXXX" 2>/dev/null)" || [ ! -d "$dir" ]; then
        echo "note:gate-tmpdir:could-not-create:$parent — running with the shared TMPDIR" >&2
        local rc1=0; "$@" || rc1=$?
        return "$rc1"
    fi
    local child rc
    # `<&0` keeps the caller's stdin for the background child (bash would
    # otherwise give an `&` job /dev/null when job control is off).
    TILLANDSIAS_GATE_TMPDIR="$dir" TMPDIR="$dir" "$@" <&0 &
    child=$!
    trap 'kill -TERM "$child" 2>/dev/null' TERM
    trap 'kill -INT "$child" 2>/dev/null' INT
    trap 'kill -HUP "$child" 2>/dev/null' HUP
    # wait returns early (>128) when a trapped signal arrives; keep waiting
    # until the child itself has exited, then take ITS status.
    # `rc=0; wait || rc=$?`, never `wait; rc=$?`: build.sh runs under set -e,
    # where a failing child's wait would end THIS shell before the removal
    # below (measured: every red gate left its tg.* dir behind).
    while :; do
        rc=0; wait "$child" || rc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    trap - TERM INT HUP
    # Anything still holding files in the dir (a daemonised helper) does not
    # stop the removal; a dir that would not go is named, never silent.
    rm -rf -- "$dir" 2>/dev/null
    [ ! -e "$dir" ] || echo "note:gate-tmpdir:left:$dir" >&2
    return "$rc"
}

# Executed rather than sourced: `scripts/gate-tmpdir.sh run <cmd...>` (the
# fixture's entry point, scripts/lua/test-gate-tmpdir.lua).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        run) shift; gate_tmpdir_run "$@"; exit $? ;;
        # build.sh's own mode: under set -e (the fixture's set -e arm).
        run-errexit) shift; set -e; gate_tmpdir_run "$@"; exit $? ;;
        *) echo "usage: scripts/gate-tmpdir.sh run <cmd...>  (or source it)" >&2; exit 2 ;;
    esac
fi

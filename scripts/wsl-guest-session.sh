#!/usr/bin/env bash
# @trace order:1567-9fgi
#
# wsl-guest-session.sh <command> [args...] — runs INSIDE the WSL2 build distro,
# as the command scripts/with-wsl2-builder.sh hands to wsl.exe, and binds the
# guest run to the HOST session that started it: when the host side goes away,
# every guest process the run started goes with it.
#
# WHY (measured on yolanda-windows 2026-10-09). Killing a Windows ./build.sh
# left the guest build running in tillandsias-build, holding the memory the kill
# was meant to free. Killing wsl.exe does hang up the guest's pty, and that ends
# the foreground process group. But build.sh runs every preflight guard under
# `setsid`, so the guards and their cargo children sit in a session of their
# own that the hangup never reaches. And a hard kill of the host SHELL on the
# capture path (lib-wsl-capture.sh keeps it as wsl.exe's parent) leaves wsl.exe
# itself alive and attached, so the guest is never told anything at all.
#
# HOW.
#   - The command runs in a cgroup of its own (cgroup v2, under
#     /sys/fs/cgroup/tillandsias-session-<pid>), which every descendant
#     inherits whatever session or process group it moves to. Without a
#     writable cgroup2 root it falls back to the parent-pid tree, plus the
#     watchdog's once-a-second snapshot of it (pid and start time), because a
#     hangup kills the intermediate shells and re-parents a setsid grandchild
#     to init before any teardown can look.
#   - The command runs in the FOREGROUND of this shell, so its signal
#     dispositions, its process group and its terminal are what they were when
#     the hop exec'd it directly. (An async child of a non-interactive shell
#     starts with SIGINT ignored, which bash cannot undo.)
#   - TEARDOWN TRIGGERS: a HUP, INT or TERM to this shell (the pty hangup when
#     wsl.exe dies); a watchdog seeing this shell lose its parent (the
#     session's Relay) while the command still runs; and the watchdog seeing
#     the host shell's Windows process gone (TILLANDSIAS_WSL_HOST_WINPID, asked
#     of tasklist.exe through interop every 5 s; an unanswerable question is
#     never read as "gone").
#   - TEARDOWN: TERM to every process of the run, up to 10 s for them to go,
#     then KILL (cgroup.kill). A run that ends on its own is never torn down,
#     and its exit code is this script's.
# Nothing is printed: after a hangup a write to the dead pty can kill the
# writer, and a run that ends normally must look exactly as it did.
set -u
_gs_sup=$$
_gs_relay=$PPID
_gs_host="${TILLANDSIAS_WSL_HOST_WINPID:-}"
_gs_root=/sys/fs/cgroup
_gs_cg=""
# TILLANDSIAS_WSL_SESSION_NO_CGROUP=1 forces the fallback (the fixture's seam).
if [ "${TILLANDSIAS_WSL_SESSION_NO_CGROUP:-}" != 1 ] && [ -f "$_gs_root/cgroup.controllers" ] && [ -w "$_gs_root/cgroup.procs" ]; then
    # Sweep EMPTY leftovers of earlier runs; rmdir refuses a populated cgroup.
    for _gs_d in "$_gs_root"/tillandsias-session-*; do
        [ -d "$_gs_d" ] && rmdir "$_gs_d" 2>/dev/null
    done
    _gs_cg="$_gs_root/tillandsias-session-$$"
    mkdir "$_gs_cg" 2>/dev/null || _gs_cg=""
fi
_gs_wd=""
# Fallback only: the parent-pid tree as remembered by the watchdog, one
# "pid|start" line per member. A hangup kills the intermediate shells first, so
# a setsid grandchild is already re-parented to init when the teardown looks;
# the snapshot still names it, and the start time keeps a recycled pid out.
_gs_snap=""
[ -n "$_gs_cg" ] || _gs_snap="/tmp/tillandsias-session-$$.pids"

# "pid|start" for each process of the run: the live parent-pid tree of this
# shell (never the watchdog's branch), plus every remembered member that is
# still the same process.
_gs_tree() {
    ps -eo pid=,ppid=,lstart= 2>/dev/null | awk -v r="$_gs_sup" -v w="${_gs_wd:-0}" -v snap="$_gs_snap" '
        { up[$1] = $2; st[$1] = $3 " " $4 " " $5 " " $6 " " $7 }
        END {
            for (p in up) { q = p; n = 0
                while (q != r && q != w && (q in up) && n < 64) { q = up[q]; n++ }
                if (q == r && p != r) { print p "|" st[p]; seen[p] = 1 } }
            if (snap != "") while ((getline line < snap) > 0) {
                split(line, a, "|")
                if ((a[1] in st) && st[a[1]] == a[2] && !(a[1] in seen) && a[1] != w) {
                    print line; seen[a[1]] = 1 } }
        }'
}

# The run's processes: the cgroup's members, or the remembered tree.
_gs_pids() {
    if [ -n "$_gs_cg" ]; then
        cat "$_gs_cg/cgroup.procs" 2>/dev/null
    else
        _gs_tree | cut -d'|' -f1
    fi
}

_gs_teardown() {
    local p n=0
    for p in $(_gs_pids); do kill -TERM "$p" 2>/dev/null; done
    while [ "$n" -lt 20 ] && [ -n "$(_gs_pids)" ]; do
        sleep 0.5
        n=$((n + 1))
    done
    if [ -n "$_gs_cg" ]; then
        { echo 1 > "$_gs_cg/cgroup.kill"; } 2>/dev/null
        n=0
        while [ "$n" -lt 10 ] && [ -n "$(_gs_pids)" ]; do sleep 0.2; n=$((n + 1)); done
        rmdir "$_gs_cg" 2>/dev/null
    else
        for p in $(_gs_pids); do kill -KILL "$p" 2>/dev/null; done
    fi
    return 0
}

# 0 only on a definite answer that the host process no longer exists.
_gs_host_gone() {
    local out
    out="$(/mnt/c/Windows/System32/tasklist.exe /FI "PID eq $_gs_host" /NH /FO CSV 2>/dev/null)" || return 1
    out="$(printf '%s' "$out" | tr -d '\r')"
    [ -n "$out" ] || return 1
    case "$out" in *",\"$_gs_host\","*) return 1 ;; esac
    return 0
}

# The watchdog: outside the cgroup (started before the move), off the pty, and
# deaf to the hangup that it exists to outlive.
(
    trap '' HUP INT
    read -r _gs_wd _ < /proc/self/stat
    tick=0
    while kill -0 "$_gs_sup" 2>/dev/null; do
        sleep 1
        pp=""
        read -r _ _ _ pp _ < "/proc/$_gs_sup/stat" 2>/dev/null || break
        if [ -n "$_gs_snap" ]; then
            _gs_tree > "$_gs_snap.tmp" 2>/dev/null && mv -f "$_gs_snap.tmp" "$_gs_snap" 2>/dev/null
        fi
        if [ "$pp" != "$_gs_relay" ]; then _gs_teardown; break; fi
        tick=$((tick + 1))
        if [ -n "$_gs_host" ] && [ $((tick % 5)) -eq 0 ] && _gs_host_gone; then
            _gs_teardown
            break
        fi
    done
    [ -z "$_gs_cg" ] || rmdir "$_gs_cg" 2>/dev/null
    [ -z "$_gs_snap" ] || rm -f "$_gs_snap" "$_gs_snap.tmp"
) </dev/null >/dev/null 2>&1 &
_gs_wd=$!

_gs_sig=0
trap '_gs_sig=129' HUP
trap '_gs_sig=130' INT
trap '_gs_sig=143' TERM
_gs_rc=0
if [ -n "$_gs_cg" ]; then
    # The child joins the cgroup BEFORE it execs, so nothing it starts escapes.
    bash -c '{ echo "$$" > "$1/cgroup.procs"; } 2>/dev/null; shift; exec "$@"' \
        tillandsias-session "$_gs_cg" "$@" || _gs_rc=$?
else
    # The fallback finds the run as this shell's descendants (and the
    # watchdog's snapshot of them).
    "$@" || _gs_rc=$?
fi
# A trap that ran during the command fires here, after the foreground child
# ended: the host is gone, so whatever the run left behind goes too.
if [ "$_gs_sig" -ne 0 ]; then
    _gs_teardown
    exit "$_gs_sig"
fi
[ -z "$_gs_cg" ] || rmdir "$_gs_cg" 2>/dev/null
exit "$_gs_rc"

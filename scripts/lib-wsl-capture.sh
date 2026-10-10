# shellcheck shell=bash
# @trace order:1563-u2yx
#
# lib-wsl-capture.sh — hand the process over to wsl.exe WITHOUT losing output
# when the caller captured stdout and stderr into ONE file.
#
# MEASURED (yolanda-windows 2026-10-08, tillandsias-build, 400 alternating
# stdout/stderr lines, 38000 bytes expected):
#   wsl.exe ... > f 2>&1        25600 bytes, 3/3 runs (= the stderr total)
#   wsl.exe ... >> f 2>&1       25600 bytes (append does not help)
#   wsl.exe ... 2>&1 | cat > f  38000 bytes
# wsl.exe writes its two streams at INDEPENDENT offsets, so when both name the
# same file the stderr writes overwrite the stdout bytes. build.sh prints
# refusals on stderr and skip notices on stdout, so `./build.sh --preflight >
# log 2>&1` lost a guard's refused:preflight:<name> line on every stack ref.
#
# tillandsias_wsl_run <wsl.exe args...>    returns wsl.exe's exit code.
# tillandsias_wsl_exec <wsl.exe args...>   the same, but never returns.
#   - fd1 and fd2 the SAME REGULAR FILE: both go through one pipe to one cat,
#     which is the only writer of the file. wsl.exe stays a direct child, so
#     TERM/INT/HUP to this shell are forwarded to it (an orphaned guest build
#     would be a new bug), and its exit code is this shell's.
#     Forwarding ends wsl.exe only; the GUEST run is bound to this shell by
#     scripts/wsl-guest-session.sh (1567-9fgi), which also covers a hard kill.
#   - anything else (a terminal, a pipe, two distinct files): plain exec, so
#     tty detection, colour and the progress renderer are unchanged.
# TILLANDSIAS_WSL_EXE overrides the binary (the fixture stubs it).

_tillandsias_same_capture_file() {
    local a b
    a="$(readlink "/proc/$$/fd/1" 2>/dev/null)" || return 1
    b="$(readlink "/proc/$$/fd/2" 2>/dev/null)" || return 1
    [ -n "$a" ] && [ "$a" = "$b" ] && [ -f "$a" ]
}

# Runs wsl.exe and RETURNS its exit code (the gate's child run, 1267-uafx).
tillandsias_wsl_run() {
    local exe="${TILLANDSIAS_WSL_EXE:-wsl.exe}"
    if ! _tillandsias_same_capture_file; then
        "$exe" "$@"
        return
    fi
    local cat_pid wsl_pid rc
    exec 3> >(exec cat)
    cat_pid=$!
    # An explicit <&0: a background command in a non-interactive shell
    # otherwise reads /dev/null, and wsl.exe forwards stdin to the guest.
    "$exe" "$@" <&0 >&3 2>&3 &
    wsl_pid=$!
    exec 3>&-
    trap 'kill -TERM "$wsl_pid" 2>/dev/null' TERM INT HUP
    rc=0
    wait "$wsl_pid" || rc=$?
    # A trapped signal interrupts wait with 128+n while the child still runs:
    # keep waiting for its real exit.
    while kill -0 "$wsl_pid" 2>/dev/null; do
        rc=0
        wait "$wsl_pid" || rc=$?
    done
    trap - TERM INT HUP
    wait "$cat_pid" 2>/dev/null || true
    return "$rc"
}

# Hands the process over to wsl.exe; never returns.
tillandsias_wsl_exec() {
    _tillandsias_same_capture_file || exec "${TILLANDSIAS_WSL_EXE:-wsl.exe}" "$@"
    tillandsias_wsl_run "$@"
    exit $?
}

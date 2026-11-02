#!/usr/bin/env bash
# @trace order:1951-vv5m
#
# lib-flaky-installs.sh — the background family for FLAKY-OPTIONAL installs.
#
# A flaky-optional install is a developer convenience the forge reaches ready
# without: linters, language servers, cargo dev tools, the Dart SDK, OpenSpec.
# Its fetch can stall on a network nobody controls (macuahuitl 2026-11-01: the
# forge-base build sat ~10 min in `pip3 install pyright bandit` at 0% CPU while
# PyPI answered the host in 0.39 s). Such an install must never hold up a build
# or a lane, so it runs here: detached, under a long budget, with one status
# file per install (output appends to TILLANDSIAS_FLAKY_LOG). A REQUIRED install (the image's own program, the lane's
# agent, the project checkout) does not belong here and keeps blocking with a
# named verdict.
#
# The audit that decided which is which:
#   plan/issues/flaky-optional-installs-audit-2026-11-01-yoga.md
#
# Status file: $(flaky_status_dir)/<name>, one line:
#   installing <utc>        started, not finished
#   ok <utc>                finished, exit 0
#   failed <reason> <utc>   finished otherwise (rc=<n> | timeout-after-<s>s)
#
# A tool the family installs gets a first-use shim (flaky_install_shim) in a
# directory LATER on PATH than the real install location, so the real binary
# wins the moment it lands and the shim only answers while it is absent.

flaky_status_dir() {
    printf '%s\n' "${TILLANDSIAS_FLAKY_STATUS_DIR:-${HOME:-/tmp}/.cache/tillandsias/flaky-installs}"
}

_flaky_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# flaky_install_start <name> <command-or-function> [args...]
# Returns at once. The command runs in the background under
# TILLANDSIAS_FLAKY_INSTALL_TIMEOUT_S (default 1800 s) and its outcome is
# written to the status file. A shell function works: the background subshell
# inherits it.
flaky_install_start() {
    local name="$1"
    shift
    local dir f budget
    dir="$(flaky_status_dir)"
    mkdir -p "$dir" 2>/dev/null || return 0
    f="$dir/$name"
    budget="${TILLANDSIAS_FLAKY_INSTALL_TIMEOUT_S:-1800}"
    printf 'installing %s\n' "$(_flaky_now)" >"$f"
    (
        "$@" &
        work=$!
        # The watcher marks the timeout BEFORE it kills, so the outcome is read
        # from a file, not from whether the watcher is still alive (a finished
        # watcher can still answer kill -0 until it is reaped). It signals the
        # installer's direct children too: a function's pip or npm is a child of
        # the background subshell, not of this one.
        rm -f "$f.timed-out"
        (
            sleep "$budget"
            : >"$f.timed-out"
            pkill -TERM -P "$work" 2>/dev/null
            kill -TERM "$work" 2>/dev/null
        ) &
        watch=$!
        rc=0
        wait "$work" || rc=$?
        kill "$watch" 2>/dev/null
        if [ "$rc" -eq 0 ]; then
            printf 'ok %s\n' "$(_flaky_now)" >"$f"
        elif [ -e "$f.timed-out" ]; then
            printf 'failed timeout-after-%ss %s\n' "$budget" "$(_flaky_now)" >"$f"
        else
            printf 'failed rc=%s %s\n' "$rc" "$(_flaky_now)" >"$f"
        fi
    ) </dev/null >>"${TILLANDSIAS_FLAKY_LOG:-/dev/null}" 2>&1 &
    return 0
}

# flaky_install_shim <tool> <name> <shim-dir>
# Writes <shim-dir>/<tool>. Put <shim-dir> at the END of PATH.
flaky_install_shim() {
    local tool="$1" name="$2" shimdir="$3"
    local f
    f="$(flaky_status_dir)/$name"
    mkdir -p "$shimdir" 2>/dev/null || return 0
    cat >"$shimdir/$tool" <<EOF
#!/usr/bin/env bash
# First-use shim for $tool, written by flaky_install_shim (order 1951-vv5m).
# Answers only while the real $tool is absent from PATH.
tool='$tool'; status='$f'; shimdir='$shimdir'
real() {
    local p rest="" IFS=:
    for p in \$PATH; do [ "\$p" = "\$shimdir" ] || rest="\${rest:+\$rest:}\$p"; done
    PATH="\$rest" command -v "\$tool"
}
deadline=\$(( \$(date +%s) + \${TILLANDSIAS_FLAKY_SHIM_WAIT_S:-30} ))
while :; do
    r="\$(real)" && exec "\$r" "\$@"
    read -r state reason _ <"\$status" 2>/dev/null || state=absent
    [ "\$state" = installing ] && [ "\$(date +%s)" -lt "\$deadline" ] || break
    sleep 1
done
case "\$state" in
    installing)
        echo "\$tool is still installing (started \$reason); try again shortly" >&2
        exit 75 ;;
    failed)
        echo "\$tool did not install: \$reason. It is retried on the next forge start; the log is /tmp/forge-lifecycle.log" >&2
        exit 127 ;;
    *)
        echo "\$tool is not installed (install state: \$state)" >&2
        exit 127 ;;
esac
EOF
    chmod 755 "$shimdir/$tool"
}

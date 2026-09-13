#!/usr/bin/env bash
# lib-wsl-exec.sh — a POSITIVE CONTROL on the wsl.exe TRANSPORT (1155-jurn).
#
# WHAT THIS IS FOR. On a Windows host, `$?` written in the COMMAND STRING passed
# to `wsl.exe -d <distro> -- bash -lc '...'` does not survive: MSYS argument
# conversion mangles `?`, so `false; echo $?` answers 0, `(exit 7); echo $?`
# answers 0, and an assignment `rc=$?` yields the EMPTY STRING — while `$$`
# comes through correctly, which is what narrows the fault to `?` specifically.
# A measurement written that way CANNOT report failure: it answers 0 whether the
# thing under test passed, failed, or never ran.
#
# THE DEFECT IS IN THE TRANSPORT, NOT IN EITHER SHELL — and getting that wrong
# is how the first version of this file was useless. A `$?` that lives INSIDE a
# sourced file is evaluated by the inner shell and is perfectly correct; only a
# `$?` written in the argument string is mangled in transit. So a canary that
# probes the shell it is running in ALWAYS PASSES, including on a host where
# every caller's measurement is being silently zeroed. Measured on esmeraldinha:
#
#   $? in the argument string        -> 0      (wrong; the defect)
#   rc=$? in the argument string     -> empty  (the assignment never happened)
#   $? inside a sourced file         -> correct
#   $$ in the argument string        -> correct (so it is `?`, not expansion)
#
# THEREFORE THIS CHECK SENDS A KNOWN ANSWER THROUGH THE HOP and reads what comes
# back, rather than asking the local shell whether it can count. It is the same
# move as the run-don't-stat convention in plan-binary-probe.sh — do not ASSUME
# the instrument works, execute something whose answer is known and check — with
# the instrument being the transport rather than a binary.
#
# WHY A CANARY AND NOT A WORKAROUND. "Remember to use a script file on Windows"
# is a discipline, and a discipline decays — fastest for whoever just wrote it
# down, because they feel inoculated. The defect's own discoverer re-committed
# it within the hour, in the session where the row was filed, and was composing
# a false fail-open report against a peer's fix when a check like this caught
# it. A canary does not depend on anyone believing they need it.
#
# USAGE — run it BEFORE the measurement it protects, never after. A channel
# discovered to be lying afterwards has already produced the number someone
# acted on.
#
#   . "$ROOT/scripts/lib-wsl-exec.sh"
#   wsl_exec_transport_ok tillandsias-build || exit 2
#   wsl_exec_transport_ok tillandsias-build --quiet
#
# Exit: 0 = the transport carried both known answers, or there is no wsl.exe hop
# to test (a non-Windows host, reported as not-applicable rather than as a pass);
# 1 = the transport dropped a status, with the verdict naming what came back.
#
# SCOPE. This reports on the transport. It does not wrap, route, or retry
# anything — whether callers should be routed through a helper that writes a
# script file automatically is a design decision 1155-jurn leaves open
# deliberately, and settling it as a side effect of writing this check would be
# the wrong way to settle it.

# Send two commands with known answers through the wsl.exe hop and compare.
wsl_exec_transport_ok() {
    local distro="${1:-}" quiet=0
    [ "${2:-}" = "--quiet" ] && quiet=1
    [ "${1:-}" = "--quiet" ] && { quiet=1; distro=""; }

    if ! command -v wsl.exe >/dev/null 2>&1; then
        [ "$quiet" -eq 1 ] || echo "skip:wsl-exec-transport:no-wsl-on-this-host"
        return 0
    fi
    if [ -z "$distro" ]; then
        echo "refused:wsl-exec-transport:no-distro-named" >&2
        echo "  usage: wsl_exec_transport_ok <distro> [--quiet]" >&2
        return 1
    fi

    local _wt_false _wt_seven _wt_bad=0
    _wt_false="$(wsl.exe -d "$distro" -- bash -lc 'false; echo "$?"' 2>/dev/null \
                 | tr -d '\r\n\0 ')"
    _wt_seven="$(wsl.exe -d "$distro" -- bash -lc '( exit 7 ); echo "$?"' 2>/dev/null \
                 | tr -d '\r\n\0 ')"

    [ "$_wt_false" = "1" ] || _wt_bad=1
    [ "$_wt_seven" = "7" ] || _wt_bad=1
    [ -z "$_wt_false" ] && _wt_false='<empty>'
    [ -z "$_wt_seven" ] && _wt_seven='<empty>'

    if [ "$_wt_bad" -eq 0 ]; then
        [ "$quiet" -eq 1 ] || echo "ok:wsl-exec-transport:carries-exit-status:$distro"
        return 0
    fi

    echo "refused:wsl-exec-transport:drops-exit-status:$distro" >&2
    echo "  sent 'false; echo \$?'      -> got ${_wt_false}  (expected 1)" >&2
    echo "  sent '( exit 7 ); echo \$?' -> got ${_wt_seven}  (expected 7)" >&2
    echo "  Any exit status written in a command string sent through this hop is" >&2
    echo "  decoration: it cannot report failure. Put the logic in a script FILE" >&2
    echo "  authored through a clean channel and execute that file (1155-jurn)." >&2
    echo "  A \$? INSIDE such a file is fine — it is the argument string that is" >&2
    echo "  mangled, so a check that probes the local shell will not see this." >&2
    echo "  MSYS_NO_PATHCONV=1 and MSYS2_ARG_CONV_EXCL='*' do NOT fix it; both" >&2
    echo "  were measured and both still return empty." >&2
    return 1
}

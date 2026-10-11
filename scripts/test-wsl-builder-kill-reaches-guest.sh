#!/usr/bin/env bash
# @trace order:1567-9fgi, order:1583-r9it
#
# Fixture: killing the HOST side of the WSL2 builder hop ends the GUEST tree.
#
# MEASURED (yolanda-windows 2026-10-09). Killing a Windows ./build.sh
# --preflight (a harness stop, then a memory reap) left the guest build running
# in tillandsias-build, still holding the memory the kill was meant to free.
# Killing wsl.exe does hang up the guest's pty, and that alone ends a plain
# child (measured: `bash -c 'sleep & sleep & wait'` left nothing behind). But
# build.sh runs every preflight guard under `setsid` (build.sh, 1352-vmbc), so
# the guards and their cargo children are in a session of their own, with no
# controlling terminal, and the hangup never reaches them.
#
# Runs the REAL scripts/with-wsl2-builder.sh against the real build distro,
# with a guest command that starts one `setsid` child and one plain child, each
# tagged by argv[0]. Kills the host side, then counts guest survivors:
#   exec path    (stdout and stderr distinct files: the builder execs wsl.exe)
#   capture path (both one file: lib-wsl-capture.sh keeps a host shell)
#   TERM, INT, HUP on each path: 0 survivors within 15 s
#   KILL on each path (nothing on the host can trap it): 0 within 30 s
#   exec HUP and capture KILL again with the cgroup turned off
#   (TILLANDSIAS_WSL_SESSION_NO_CGROUP=1), for wsl-guest-session.sh's fallback
#   HUNG INTEROP (1583-r9it): the watchdog's host poll goes to a stub tasklist
#   that never returns (TILLANDSIAS_WSL_SESSION_TASKLIST), and the host is
#   killed while it is out: the tree AND the watchdog are gone within 30 s and
#   the session log names the trigger. Pre-fix shape: a watchdog blocked in
#   tasklist.exe for 26 h (yolanda 2026-10-10). Sabotage (the 5 s bound
#   removed): FAIL, survivors=2, three session processes, no trigger logged.
#   STOPPED PIPELINE (1583-r9it), recorded not asserted: the caller of
#   `builder ... 2>&1 | cat > log` is killed and the builder's exec'd wsl.exe
#   is not. Measured: OUTSIDE THE GUARD'S MODEL; the session log shows the
#   watched host winpid polled "alive", so the session is attached and runs.
# Each arm first checks the setsid child is in (or, for the fallback, out of)
# the run's tillandsias-session cgroup, so a green arm cannot come from the
# other mechanism.
# INT on the exec path is NOT delivered at all: MSYS cannot signal the native
# wsl.exe the builder exec'd (measured: it stays, with or without job control).
# Nothing is killed, so nothing can be orphaned; that arm passes only when the
# host AND both guest children are all still running.
# PRE-FIX RESULT (the 8 cgroup-less arms as first written, before wiring):
# 8/8 FAIL. TERM, HUP and exec KILL left the setsid child (survivors=1), and
# INT and capture KILL left both, because wsl.exe outlives a killed host shell.
#
# Off Windows, without wsl.exe, or without the build distro, skips by name.
# Never imports or initialises the distro itself.
set -u
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "skip:wsl-builder-kill-fixture:not-a-windows-host"; exit 0 ;;
esac
if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "skip:wsl-builder-kill-fixture:no-wsl-exe"
    exit 0
fi
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DISTRO="${TILLANDSIAS_BUILD_DISTRO:-tillandsias-build}"
if ! wsl.exe --list --quiet 2>/dev/null | tr -d '\0\r' | grep -qxF "$DISTRO"; then # sigpipe-ok: wsl --list is a few lines, written before grep reads
    echo "skip:wsl-builder-kill-fixture:no-build-distro:$DISTRO"
    exit 0
fi
# Job control: an async job of a non-interactive shell starts with SIGINT
# ignored, which bash in the host shell could then neither trap nor reset.
set -m
TMP="$(mktemp -d)"
TAG="k9fgi$$x$RANDOM"
guest() { printf '%s\n' "$1" | wsl.exe -d "$DISTRO" -u root -- bash -s 2>/dev/null | tr -d '\r'; }
survivors() { guest "pgrep -fc '^$1-' || true"; }
cleanup() {
    guest "pkill -KILL -f '^$TAG' || true" >/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

fails=0
cantrun=0
arm() { # arm <exec|capture> <signal> <deadline-seconds> <cg|tree>
    local path="$1" sig="$2" limit="$3" mode="$4" t="$TAG$1$2$4" cmd host n c cgl incg nocg=""
    [ "$mode" = tree ] && nocg=1
    cmd="setsid bash -c 'exec -a $t-s sleep 900' & bash -c 'exec -a $t-p sleep 900' & wait"
    if [ "$path" = exec ]; then
        ( cd "$REPO_ROOT" && TILLANDSIAS_WSL_SESSION_NO_CGROUP="$nocg" exec bash scripts/with-wsl2-builder.sh bash -c "$cmd" ) \
            </dev/null >"$TMP/$t.out" 2>"$TMP/$t.err" &
    else
        ( cd "$REPO_ROOT" && TILLANDSIAS_WSL_SESSION_NO_CGROUP="$nocg" exec bash scripts/with-wsl2-builder.sh bash -c "$cmd" ) \
            </dev/null >"$TMP/$t.log" 2>&1 &
    fi
    host=$!
    n=0
    c=0
    until [ "$n" -ge 60 ]; do
        c="$(survivors "$t")"
        [ "$c" = 2 ] && break
        n=$((n + 1))
        sleep 1
    done
    if [ "$c" != 2 ]; then
        echo "could-not-run: $path $sig $mode: the guest children never started (count=$c)"
        cantrun=$((cantrun + 1))
        kill -KILL "$host" 2>/dev/null
        return
    fi
    # Positive checkpoint: the run is where this arm says it is, so a green
    # arm cannot come from the other mechanism.
    cgl="$(guest "cat /proc/\$(pgrep -f '^$t-s' | head -n 1)/cgroup 2>/dev/null")"
    case "$cgl" in *tillandsias-session-*) incg=cg ;; *) incg=tree ;; esac
    if [ "$incg" != "$mode" ]; then
        echo "FAIL: $path $sig $mode: the setsid child is not where this arm puts it (cgroup: ${cgl:-unreadable})"
        fails=$((fails + 1))
        guest "pkill -KILL -f '^$t-' || true" >/dev/null
        kill -KILL "$host" 2>/dev/null
        { wait "$host"; } 2>/dev/null
        return
    fi
    kill "-$sig" "$host" 2>/dev/null
    n=0
    until [ "$n" -ge "$limit" ]; do
        sleep 1
        n=$((n + 1))
        c="$(survivors "$t")"
        [ "$c" = 0 ] && break
    done
    halive=0
    kill -0 "$host" 2>/dev/null && halive=1
    if [ "$c" = 0 ]; then
        echo "ok:   $path $sig $mode: the guest tree ended (${n}s, limit ${limit}s)"
    elif [ "$path$sig" = execINT ] && [ "$halive" = 1 ] && [ "$c" = 2 ]; then
        # MSYS cannot deliver SIGINT to the native wsl.exe the builder exec'd
        # (measured: the process stays, with or without job control). Nothing
        # was killed, so nothing is orphaned: the run is still attached.
        echo "ok:   $path $sig $mode: not delivered to an exec'd native wsl.exe; host and guest both still run, nothing orphaned"
    else
        echo "FAIL: $path $sig $mode: survivors=$c host-alive=$halive after ${limit}s ($(guest "pgrep -fa '^$t-' | cut -d' ' -f2 | tr '\n' ' '"))"
        fails=$((fails + 1))
    fi
    guest "pkill -KILL -f '^$t-' || true" >/dev/null
    kill -KILL "$host" 2>/dev/null
    { wait "$host"; } 2>/dev/null
}

for p in exec capture; do
    for s in TERM INT HUP; do
        arm "$p" "$s" 15 cg
    done
    arm "$p" KILL 30 cg
done
# The fallback without a cgroup: the hangup path and the winpid path.
arm exec HUP 15 tree
arm capture KILL 30 tree

# ORDER 1583-r9it. A session's supervisor and watchdog, found by tag.
sessions() { guest "pgrep -fc 'wsl-guest-session.sh bash -c .*$1-s' || true"; }

# HUNG INTEROP: the watchdog's host poll never answers (a stub tasklist that
# hangs, the shape measured on yolanda: a 26 h watchdog blocked in
# tasklist.exe). The host is killed WHILE the poll is out. The guest tree must
# still end, the watchdog must not be left behind, and the session log must
# name the trigger. PRE-FIX: the watchdog stays blocked in the stub forever.
STUB_REL="target/plan-scratch/fx-r9it-hang-tasklist.sh"
mkdir -p "$REPO_ROOT/target/plan-scratch"
printf '#!/bin/sh\n: > target/plan-scratch/fx-r9it-called\nexec sleep 3600\n' >"$REPO_ROOT/$STUB_REL"
rm -f "$REPO_ROOT/target/plan-scratch/fx-r9it-called"
t="${TAG}hung"
cmd="setsid bash -c 'exec -a $t-s sleep 900' & bash -c 'exec -a $t-p sleep 900' & wait"
( cd "$REPO_ROOT" && TILLANDSIAS_WSL_SESSION_TASKLIST="$STUB_REL" exec bash scripts/with-wsl2-builder.sh bash -c "$cmd" ) \
    </dev/null >"$TMP/$t.out" 2>"$TMP/$t.err" &
host=$!
n=0; c=0
until [ "$n" -ge 60 ]; do c="$(survivors "$t")"; [ "$c" = 2 ] && break; n=$((n + 1)); sleep 1; done
supv="$(guest "pgrep -fo 'wsl-guest-session.sh bash -c .*$t-s' || true")"
n=0
until [ -f "$REPO_ROOT/target/plan-scratch/fx-r9it-called" ] || [ "$n" -ge 20 ]; do n=$((n + 1)); sleep 1; done
if [ "$c" != 2 ] || [ ! -f "$REPO_ROOT/target/plan-scratch/fx-r9it-called" ]; then
    echo "could-not-run: hung-interop: children=$c, the stub was never called"
    cantrun=$((cantrun + 1))
    kill -KILL "$host" 2>/dev/null
else
    kill -KILL "$host" 2>/dev/null
    n=0; c=1; w=1
    until [ "$n" -ge 30 ]; do
        sleep 1; n=$((n + 1))
        c="$(survivors "$t")"; w="$(sessions "$t")"
        [ "$c" = 0 ] && [ "$w" = 0 ] && break
    done
    log="$(guest "cat /tmp/tillandsias-session-$supv.log 2>/dev/null")"
    if [ "$c" = 0 ] && [ "$w" = 0 ] && grep -q 'trigger:' <<<"$log"; then # sigpipe-ok: herestring
        echo "ok:   exec KILL hung-interop: tree and watchdog gone (${n}s), log names: $(grep -m1 'trigger:' <<<"$log" | cut -d' ' -f2-)" # sigpipe-ok: herestring
    else
        echo "FAIL: exec KILL hung-interop: survivors=$c session-procs=$w after ${n}s; log=[$(tr '\n' '|' <<<"$log")]"
        fails=$((fails + 1))
    fi
fi
guest "pkill -KILL -f '^$t-|wsl-guest-session.sh bash -c .*$t-s|fx-r9it-hang' || true" >/dev/null
{ wait "$host"; } 2>/dev/null
rm -f "$REPO_ROOT/$STUB_REL" "$REPO_ROOT/target/plan-scratch/fx-r9it-called"

# STOPPED PIPELINE: what a harness stop does on Windows. The builder runs
# under a caller (`... 2>&1 | cat > log`) and the CALLER is killed; the
# builder's exec'd wsl.exe, the process the guard watches, is not. Recorded,
# not asserted either way: the outcome and the session log's own account.
t="${TAG}pipe"
cmd="setsid bash -c 'exec -a $t-s sleep 900' & bash -c 'exec -a $t-p sleep 900' & wait"
printf 'bash scripts/with-wsl2-builder.sh bash -c "$1" 2>&1 | cat > "$2"\n' >"$TMP/pipe.sh"
( cd "$REPO_ROOT" && exec bash "$TMP/pipe.sh" "$cmd" "$TMP/$t.log" ) </dev/null &
caller=$!
n=0; c=0
until [ "$n" -ge 60 ]; do c="$(survivors "$t")"; [ "$c" = 2 ] && break; n=$((n + 1)); sleep 1; done
supv="$(guest "pgrep -fo 'wsl-guest-session.sh bash -c .*$t-s' || true")"
kill -KILL "$caller" 2>/dev/null
n=0
until [ "$n" -ge 20 ]; do sleep 1; n=$((n + 1)); c="$(survivors "$t")"; [ "$c" = 0 ] && break; done
log="$(guest "cat /tmp/tillandsias-session-$supv.log 2>/dev/null")"
if [ "$c" = 0 ]; then
    echo "ok:   stopped pipeline: the guard ended the guest tree (${n}s); log: $(tr '\n' '|' <<<"$log")"
else
    echo "note: stopped pipeline: OUTSIDE THE GUARD'S MODEL. Killing the caller left the builder's wsl.exe (the host process the guard watches) alive, so the session is attached and running; survivors=$c after ${n}s. Log: $(tr '\n' '|' <<<"$log")"
fi
guest "pkill -KILL -f '^$t-' || true" >/dev/null
for p in $(ps | awk -v pp="$caller" '$2 == pp && /wsl/ { print $1 }'); do kill -KILL "$p" 2>/dev/null; done
if [ "$cantrun" -gt 0 ]; then echo "could-not-run:wsl-builder-kill-fixture:arms=$cantrun"; exit 3; fi
if [ "$fails" -gt 0 ]; then echo "refused:wsl-builder-kill-fixture:failed=$fails"; exit 1; fi
echo "ok:wsl-builder-kill-fixture:11"

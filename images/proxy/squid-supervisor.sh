#!/usr/bin/env bash
# =============================================================================
# squid-supervisor.sh — crash supervision for the enclave proxy (order 767-es4w).
#
#   squid-supervisor <service-name> <command> [args...]
#
# WHY THIS EXISTS, and why it is NOT a copy of harness-supervisor.sh.
#
# 767-es4w: 263 recorded squid SIGSEGVs between 2026-06-30 and 2026-08-12, and
# a `tillandsias-proxy` container that sat Exited(139) for two days with zero
# alarms. Two DIFFERENT things hide behind that one exit code, and telling
# them apart is this script's whole job:
#
#   1. BENIGN EXIT-TIME TEARDOWN CRASH. Measured on macuahuitl 2026-08-17:
#      an IDLE proxy, given `podman stop`, logs
#          "Squid Cache (Version 6.12): Exiting normally."
#      — swap log written, logs closed, PID file removed — and THEN segfaults
#      inside libc exit() running the global Store::Controller destructor:
#          HttpHeader::clean <- HttpReply::clean <- ~HttpReply <- ~MemObject
#          <- StoreEntry::destroyMemObject <- destroyStoreEntry <- hashFreeItems
#          <- Store::Controller::~Controller <- exit()
#      Reproduced 100% of the time on squid 6.9 AND 6.12, with zero traffic,
#      with the disk cache removed, with the whole store disabled, with the
#      cache_peer removed, and with ssl-bump removed. It costs nothing — every
#      byte is already flushed — but it turns EVERY ordered shutdown into an
#      Exited(139), which is precisely why nobody could tell a stopped proxy
#      from a dead one for two days.
#
#   2. A REAL CRASH: squid dying of a fatal signal while it is serving. That
#      is an outage; it must be loud and it must be restarted.
#
# Left alone, (1) makes (2) invisible. So the central act here is to
# DISCRIMINATE, using the same mechanism 767-nkkq's harness-supervisor uses:
# the supervisor knows whether IT was asked to stop.
#
#   * asked to stop, child exits cleanly        -> silent passthrough;
#   * asked to stop, child dies of a signal     -> case (1): ONE named line
#     `note:proxy-exit-teardown-crash:...` on BOTH streams, an evidence file,
#     its own counter, and **exit 0** — the shutdown was ordered and it
#     completed. This is what gives Exited(139) its meaning back;
#   * NOT asked to stop, child dies of a signal -> case (2): ONE named line
#     `fail:proxy-crashed:...` on BOTH streams carrying the running crash
#     count, an evidence file, and a BOUNDED restart;
#   * flap cap exceeded                         -> a final
#     `fail:proxy-crashed:...:action=giveup` and a truthful nonzero exit, so
#     the container really dies and the lane fails loudly instead of spinning.
#
# POLICY DIFFERENCE FROM 767-nkkq, deliberate. harness-supervisor NEVER
# restarts: re-running a crashed agent's prompt unattended is dangerous. An
# infrastructure service is the opposite case — restarting squid is correct
# and the sin is silence. So the counter and its visibility, not the restart,
# are the deliverable (782-dpby's framing).
#
# Evidence surface (741-3y48: the container is ephemeral): the stdout/stderr
# lines are the primary durable channel — they land in `podman logs
# tillandsias-proxy`, which `tillandsias --diagnostics` already streams. A
# copy plus running counters go to $TILLANDSIAS_PROXY_CRASH_STATE_DIR
# (default /var/log/squid/crash-state), readable with `podman exec` and by
# scripts/proxy-crash-report.sh.
#
# DISTRO: Alpine 3.22, bash 3.2 floor (scripts/check-bash-dialect.sh). No
# arrays, no [[ ]], no associative arrays, no GNU-only date formats — the
# crash-time window is a space-separated string of epoch seconds.
# =============================================================================
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: squid-supervisor <service-name> <command> [args...]" >&2
    exit 2
fi

SERVICE_NAME="$1"
shift
CHILD_CMD="$*"

STATE_DIR="${TILLANDSIAS_PROXY_CRASH_STATE_DIR:-/var/log/squid/crash-state}"
# Flap bound: more than RESTART_MAX real crashes inside RESTART_WINDOW seconds
# means restarting is not helping — give up loudly rather than hide a crash
# loop behind a container that always looks "up".
RESTART_MAX="${TILLANDSIAS_PROXY_RESTART_MAX:-5}"
RESTART_WINDOW="${TILLANDSIAS_PROXY_RESTART_WINDOW:-300}"
BACKOFF_MAX="${TILLANDSIAS_PROXY_BACKOFF_MAX:-30}"

crash_count=0
teardown_count=0
backoff=1
# Space-separated epoch seconds of real crashes, pruned to RESTART_WINDOW.
crash_times=""

child_pid=0
# Set once and NEVER cleared: from the moment an ordered stop is requested,
# this supervisor must not resurrect the service, and any fatal child death
# is the teardown case rather than a crash.
stop_requested=0
forward() { # <signal>
    stop_requested=1
    if [ "$child_pid" -gt 0 ]; then
        kill -s "$1" "$child_pid" 2>/dev/null
    fi
}
trap 'forward TERM' TERM
trap 'forward INT' INT

now_epoch() { date -u +%s 2>/dev/null || echo 0; }
now_stamp() { date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown; }

# Sleep in 1s slices so a stop request during backoff is honoured promptly —
# a single `sleep 30` would defer the trap past podman's stop timeout and turn
# an ordered shutdown into a SIGKILL.
interruptible_sleep() { # <seconds>
    local remaining
    remaining="$1"
    while [ "$remaining" -gt 0 ]; do
        if [ "$stop_requested" -eq 1 ]; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
}

# Keep only crash timestamps inside the rolling window; echo the survivors.
prune_window() { # <now>
    local now keep t
    now="$1"
    keep=""
    for t in $crash_times; do
        if [ $((now - t)) -lt "$RESTART_WINDOW" ]; then
            keep="$keep $t"
        fi
    done
    echo "$keep"
}

# Persist counters + a per-event report. Never fatal: an unwritable state dir
# must not take the proxy down, because the stdout/stderr line is the channel
# that actually matters.
write_evidence() { # <kind> <verdict> <signal> <rc> <stamp>
    local kind verdict sig rc stamp
    kind="$1"; verdict="$2"; sig="$3"; rc="$4"; stamp="$5"
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    echo "$crash_count" > "$STATE_DIR/crash-count" 2>/dev/null || true
    echo "$teardown_count" > "$STATE_DIR/exit-teardown-count" 2>/dev/null || true
    {
        echo "verdict: $verdict"
        echo "kind: $kind"
        echo "service: $SERVICE_NAME"
        echo "signal: $sig"
        echo "rc: $rc"
        echo "ts: $stamp"
        echo "crash_count: $crash_count"
        echo "exit_teardown_count: $teardown_count"
        echo "cmd: $CHILD_CMD"
        echo "supervision: 767-es4w squid-supervisor"
    } > "$STATE_DIR/last-event" 2>/dev/null || true
    cp "$STATE_DIR/last-event" "$STATE_DIR/event-$kind-$stamp-$$.txt" 2>/dev/null || true
}

# ONE machine-grepable line, on BOTH streams (767-nkkq: launchers capture
# different streams, and a verdict only one of them sees is a verdict lost).
say_both() { # <line>
    echo "$1"
    echo "$1" >&2
}

while :; do
    "$@" &
    child_pid=$!

    rc=127
    while :; do
        if wait "$child_pid"; then
            rc=0
            break
        else
            rc=$?
            # `wait` is interrupted by a trapped signal; if the child is still
            # alive that is all this was, so keep waiting for its real status.
            kill -0 "$child_pid" 2>/dev/null || break
        fi
    done

    # Ordinary exit (including squid's own FATAL config refusals): pass the
    # code through untouched and say nothing. The happy path stays byte-silent.
    if [ "$rc" -lt 128 ]; then
        exit "$rc"
    fi

    sig=$((rc - 128))
    stamp="$(now_stamp)"

    if [ "$stop_requested" -eq 1 ]; then
        # We were asked to stop. A stop-shaped signal is a plain ordered
        # shutdown; ANY OTHER fatal signal here is the measured exit-time
        # teardown crash — named, counted, evidenced, but not an alarm, not a
        # restart, and the container's exit code is normalised to 0.
        if [ "$sig" -eq 15 ] || [ "$sig" -eq 2 ] || [ "$sig" -eq 1 ]; then
            exit "$rc"
        fi
        teardown_count=$((teardown_count + 1))
        verdict="note:proxy-exit-teardown-crash:service=${SERVICE_NAME}:signal=${sig}:rc=${rc}:teardowns=${teardown_count}:action=normalised-to-0"
        say_both "$verdict"
        write_evidence teardown "$verdict" "$sig" "$rc" "$stamp"
        exit 0
    fi

    # Nobody asked it to stop: a real crash, mid-service.
    crash_count=$((crash_count + 1))
    now="$(now_epoch)"
    crash_times="$(prune_window "$now") $now"
    recent=0
    for t in $crash_times; do
        recent=$((recent + 1))
    done

    if [ "$recent" -gt "$RESTART_MAX" ]; then
        verdict="fail:proxy-crashed:service=${SERVICE_NAME}:signal=${sig}:rc=${rc}:crashes=${crash_count}:recent=${recent}:window=${RESTART_WINDOW}:action=giveup"
        say_both "$verdict"
        write_evidence giveup "$verdict" "$sig" "$rc" "$stamp"
        # Truthful nonzero exit: the container really dies, the lane fails
        # loudly, and no supervisor pretends a flapping proxy is healthy.
        exit "$rc"
    fi

    verdict="fail:proxy-crashed:service=${SERVICE_NAME}:signal=${sig}:rc=${rc}:crashes=${crash_count}:recent=${recent}:window=${RESTART_WINDOW}:action=restart:backoff=${backoff}"
    say_both "$verdict"
    write_evidence crash "$verdict" "$sig" "$rc" "$stamp"

    interruptible_sleep "$backoff"
    if [ "$stop_requested" -eq 1 ]; then
        exit 0
    fi
    backoff=$((backoff * 2))
    if [ "$backoff" -gt "$BACKOFF_MAX" ]; then
        backoff="$BACKOFF_MAX"
    fi
done

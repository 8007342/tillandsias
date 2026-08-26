#!/usr/bin/env bash
# @trace order:899-6pwv
#
# Capture a command's output to an evidence file, then show an excerpt.
# The artifact and the excerpt do not share a pipe, so the excerpt cannot
# truncate the artifact and cannot replace the command's exit status.
#
#   scripts/capture.sh [--tail N|--head N|--quiet] <logfile> -- <cmd> [args...]
#
# Exits with the COMMAND's status. Writes `<logfile>.exit` and appends a
# terminator line to `<logfile>`; `--verify <logfile>` re-reads both.
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
#
# `<cmd> 2>&1 | tee "$LOG" | head -30` truncates $LOG. `head` exits after 30
# lines, SIGPIPEs `tee`, and `tee` dies mid-write — so the evidence file for a
# PASSING step stops early with no result line while the terminal output looks
# perfectly normal. Observed on yolanda during the v0.4.260826.1 Windows
# curl-install e2e: 75 lines, no RESULT, command succeeded.
#
# `<cmd> | tail -40` is the same family with a different loss. `tail` consumes
# everything, so the file is not truncated — but the 40-line WINDOW is, and on
# macuahuitl 2026-08-26 a gate run this way hid every step the reader needed,
# including the one they had just added. That was done by the host that had
# filed this packet one cycle earlier.
#
# BE PRECISE ABOUT THE SECOND HALF, because the loose version of this claim is
# wrong and this file is where someone will come to check it. `$?` after a pipe
# is the LAST command's status ONLY when `pipefail` is unset. That is the
# default for an interactive shell, for `bash -c`, and for any ad-hoc command
# typed at a prompt; most scripts in this repo set `pipefail` and do propagate.
# So the status loss is real exactly where it is least visible — outside the
# carefully written scripts. On the macuahuitl run the gate had genuinely
# passed, so the reported 0 was correct and the truncated window was the whole
# of the damage. Verified both ways in scripts/test-capture-helper.sh arm 2.
#
# THE DOCUMENTATION DID NOT WORK. `skills/meta-orchestration/SKILL.md` warns
# against exactly this, with a dated incident, and the same host walked into it
# twice more. The skill states the principle it then failed to apply: "a guard
# only an attentive agent honors is a suggestion, not a constraint". This is
# the constraint.
#
# THE FAILURE SELECTS FOR UNREAD EVIDENCE. Truncation is silent at capture time
# and only discoverable by reading the artifact — which nobody does when the
# step PASSED. A failing step gets its log read; a passing step's log is filed
# as evidence, unread. So the runs least likely to be checked are the ones most
# likely to be wrong.
#
# WHAT THE TERMINATOR BUYS. A log ending in `### capture-complete rc=… ###` was
# written to completion. A log without it was cut off — by SIGPIPE, a killed
# process, a full disk, or a reader who stopped early. That distinction did not
# previously exist in any artifact this fleet commits, which is why "the file
# looked fine" was an available conclusion.
#
# HONEST LIMIT: if the captured command itself prints the terminator string,
# --verify can be fooled. Nothing in-tree does, and the alternative (a wrapper
# that rewrites its child's output) costs more than it saves.
set -uo pipefail

TERMINATOR_PREFIX='### capture-complete'

usage() {
    cat >&2 <<'EOF'
usage: capture.sh [--tail N|--head N|--quiet] <logfile> -- <cmd> [args...]
       capture.sh --verify <logfile>

  --tail N   show the last N lines after the command finishes (default 30)
  --head N   show the first N lines instead
  --quiet    capture only, show nothing
  --verify   exit 0 if <logfile> was written to completion, 1 otherwise
EOF
    exit 2
}

verify_one() {
    local log="$1" last rc lines actual
    if [ ! -f "$log" ]; then
        echo "missing:$log" >&2
        return 1
    fi
    last="$(tail -n 1 "$log" 2>/dev/null)"
    case "$last" in
        "$TERMINATOR_PREFIX"*) ;;
        *)
            echo "truncated:$log: no terminator — the capture did not run to completion" >&2
            return 1
            ;;
    esac
    # The recorded line count must match what is actually there. A file that
    # gained the terminator but lost lines in between is still damaged.
    lines="$(printf '%s' "$last" | sed -n 's/.*lines=\([0-9]*\).*/\1/p')"
    rc="$(printf '%s' "$last" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
    actual="$(($(wc -l < "$log") - 1))"
    if [ -n "$lines" ] && [ "$lines" != "$actual" ]; then
        echo "damaged:$log: terminator claims lines=$lines, file has $actual" >&2
        return 1
    fi
    echo "ok:capture-complete:$log:rc=${rc:-?}:lines=${lines:-?}"
    return 0
}

[ $# -ge 1 ] || usage

if [ "$1" = "--verify" ]; then
    shift
    [ $# -ge 1 ] || usage
    st=0
    for f in "$@"; do
        verify_one "$f" || st=1
    done
    exit "$st"
fi

mode=tail
count=30
while [ $# -gt 0 ]; do
    case "$1" in
        --tail)  mode=tail;  count="${2:-30}"; shift 2 ;;
        --head)  mode=head;  count="${2:-30}"; shift 2 ;;
        --quiet) mode=quiet; shift ;;
        --) shift; break ;;
        -*) usage ;;
        *)  break ;;
    esac
done

[ $# -ge 1 ] || usage
LOG="$1"; shift
if [ "${1:-}" = "--" ]; then shift; fi
[ $# -ge 1 ] || usage

case "$count" in *[!0-9]*|"") usage ;; esac

logdir="$(dirname -- "$LOG")"
[ -d "$logdir" ] || mkdir -p "$logdir" || exit 1

# THE WHOLE POINT: a redirect, not a pipe. No second process shares this
# command's stdout, so nothing downstream can close the pipe early and nothing
# downstream can replace $?.
"$@" > "$LOG" 2>&1
rc=$?

lines="$(wc -l < "$LOG" 2>/dev/null | tr -d '[:space:]')"
bytes="$(wc -c < "$LOG" 2>/dev/null | tr -d '[:space:]')"
printf '%s rc=%s lines=%s bytes=%s ###\n' "$TERMINATOR_PREFIX" "$rc" "${lines:-0}" "${bytes:-0}" >> "$LOG"
printf '%s\n' "$rc" > "$LOG.exit"

# The excerpt reads the FINISHED file. It is a separate step, so how much of it
# a human wanted to see has no bearing on what was stored.
case "$mode" in
    tail) tail -n "$count" -- "$LOG" ;;
    head) head -n "$count" -- "$LOG" ;;
    quiet) : ;;
esac

exit "$rc"

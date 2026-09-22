#!/usr/bin/env bash
# @trace order:1176-fn2p
# @trace order:1047-h88p (the job ceiling this sits below)
#
# Refuse a gate BY NAME on a host with too little memory to start it, instead of
# letting it be SIGKILLed minutes later with a log that ends mid-line.
#
# WHAT THIS IS NOT, and the distinction is the whole design. This is NOT a
# capacity predictor: it does not know whether this tree will fit in this host's
# memory, and 1176-fn2p explicitly rules that out of scope ("Neither needs to
# make the build fit; both need the failure to be LEGIBLE"). It answers one
# narrow question — is there so little memory available RIGHT NOW that starting
# the expensive phases is pointless — and it answers it in seconds.
#
# THE FLOOR IS DELIBERATELY FAR BELOW ANY HOST OBSERVED TO COMPLETE, because
# 1176-fn2p's first negative control is that the floor must not become a second
# cliff refusing hosts that would have finished. Measured on yoga (Silverblue,
# 14.8 GiB MemTotal), which completes this gate routinely: 11-12 GiB
# MemAvailable at rest. The default floor is 1 GiB. A host under 1 GiB available
# is not going to run rustc on this workspace, and a host over it is left
# entirely alone — which is the correct division of labour between this check
# and the OOM post-mortem: the floor catches the START state, the post-mortem
# catches the RUN state, and lenovinha's two kills were the second kind.
#
# MemAvailable, NOT MemTotal. MemTotal is a property of the machine and cannot
# change between a gate that works and one that does not; 1176-fn2p's own
# measurement shows the host's total was constant across five successful lands
# and two kills on the same day. What moved was what was free.
set -uo pipefail

# ORDER 1354-apns. EACH could-not-run ALSO ENDS ON A `skip:` LINE, because the
# readers that score this decider know exactly one word for "nothing was
# asserted" and it is not this one.
#
# THE RULE IS ALREADY RIGHT IN BOTH READERS AND CANNOT HEAR THIS SPELLING.
# build.sh's preflight matches `^skip:` under the comment "A NAMED SKIP IS NOT A
# FAILURE, whatever it exits with (1273-4mak)"; run-litmus-test.sh recognises
# `skip:` on the LAST non-empty line. MEASURED on macOS 2026-09-22: this
# decider's honest `could-not-run:...no-meminfo` was scored
# `refused:preflight:check-gate-memory-floor`, and `./build.sh --preflight`
# therefore exited 1 on a Mac regardless of the tree — with the preflight now
# mandatory before every `gh pr ready`, that is a step no macOS author can
# satisfy.
#
# THE could-not-run LINE STAYS, and the exit status stays. A reader must still
# see WHICH instrument could not answer and why — that is 965-sxec's channel and
# the reason this decider refuses to answer "fine" from a file it never read. A
# terminal `skip:` satisfies both readers at once: the preflight matches it
# anywhere, the litmus runner reads the last line.
#
# WHAT IS NOT TOUCHED: the below-floor path still emits
# `refused:gate:insufficient-memory` and is still scored a FAILURE. Turning that
# into a skip would make this guard decoration, which is the direction 1176-fn2p
# exists to prevent.

FLOOR_MB="${TILLANDSIAS_GATE_MEMORY_FLOOR_MB:-1024}"
MEMINFO=/proc/meminfo

while [ $# -gt 0 ]; do
    case "$1" in
        --meminfo-from) MEMINFO="${2:-}"; shift 2 ;;
        --floor-mb)     FLOOR_MB="${2:-}"; shift 2 ;;
        *) echo "usage: check-gate-memory-floor.sh [--meminfo-from FILE] [--floor-mb N]" >&2; exit 2 ;;
    esac
done

case "$FLOOR_MB" in
    ''|*[!0-9]*)
        echo "could-not-run:gate-memory:bad-floor:$FLOOR_MB (TILLANDSIAS_GATE_MEMORY_FLOOR_MB must be an integer in MB)"
        echo "skip:gate-memory:bad-floor"
        exit 3 ;;
esac

# NOT A PLATFORM CLAIM. A host with no /proc/meminfo (darwin, or a stripped
# container) is one this check cannot answer for, and saying so is the honest
# verdict — 965-sxec's channel. Answering "fine" would be a capacity claim from
# an instrument that never read anything.
if [ ! -r "$MEMINFO" ]; then
    echo "could-not-run:gate-memory:no-meminfo:$MEMINFO (this host exposes no readable MemAvailable; nothing is asserted about its memory)"
    echo "skip:gate-memory:no-meminfo"
    exit 3
fi

avail_kb="$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB.*/\1/p' "$MEMINFO" | head -1)"
case "$avail_kb" in
    ''|*[!0-9]*)
        # MemAvailable arrived in Linux 3.14; an older or synthetic meminfo has
        # only MemFree, which systematically UNDER-reports by the reclaimable
        # page cache and would refuse healthy hosts. Refusing to guess is right.
        echo "could-not-run:gate-memory:no-memavailable (read $MEMINFO but it carries no MemAvailable line; MemFree is not a substitute and would under-report)"
        echo "skip:gate-memory:no-memavailable"
        exit 3 ;;
esac

avail_mb=$(( avail_kb / 1024 ))

if [ "$avail_mb" -lt "$FLOOR_MB" ]; then
    echo "refused:gate:insufficient-memory (${avail_mb}MB available, floor ${FLOOR_MB}MB — read from $MEMINFO)"
    echo "  The expensive phases would very likely be SIGKILLed partway with no verdict," >&2
    echo "  which is indistinguishable from a hang (1176-fn2p). Refusing in seconds instead." >&2
    echo "  This is a LEGIBILITY floor, not a capacity claim: a host above it is never refused here." >&2
    echo "  Raise or lower it deliberately with TILLANDSIAS_GATE_MEMORY_FLOOR_MB." >&2
    exit 1
fi

echo "ok:gate-memory:${avail_mb}MB available, floor ${FLOOR_MB}MB"
exit 0

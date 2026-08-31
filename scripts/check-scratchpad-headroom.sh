#!/usr/bin/env bash
# ORDER 915-wkm2 — report SCRATCHPAD QUOTA HEADROOM, not filesystem free space.
#
# THE TRAP THIS EXISTS FOR. The agent scratchpad lives on tmpfs. systemd sizes
# /tmp at 50% of RAM, but a usrquota can sit far below that — so `df` reports
# gigabytes free while every write returns EDQUOT. The host stays healthy and
# only the agent's tooling dies, which presents as "my shell is broken" rather
# than "I filled a disk".
#
# MEASURED on two hosts 2026-08-26, and the spread is why this check is not a
# percentage:
#
#   macuahuitl  quota 25564 MB (24.96 GiB)   df size 32 GB
#   lenovinha   quota  5525 MB ( 5.4 GiB)    df size 6.8 GB, "5.2G avail"
#
# A 4.6x spread in the limit. A percentage threshold tuned to one host is wrong
# on the other, so the threshold here is ABSOLUTE and derived from what the work
# actually costs: one cold Rust `target/` was measured at 2.6-4.4 GB. If less
# than that fits, a build in the scratchpad cannot succeed — whatever percentage
# it represents.
#
# ADVISORY, NEVER A GATE. A cycle must not fail because a host is low on scratch;
# it must be TOLD, early, while it can still choose where to build. A check that
# red-lights the gate for a capacity condition is the 888-miiy shape.
#
# Verdict grammar, one line, matching
#   ^(ok:scratchpad-headroom:[0-9]+m-of-[0-9]+m|warn:scratchpad-headroom-low:[0-9]+m-of-[0-9]+m|warn:scratchpad-disk-low:[0-9]+m|skip:(no-quota|no-scratchpad|no-quota-tool))$
set -uo pipefail

SCRATCH="${TILLANDSIAS_SCRATCHPAD_DIR:-${TMPDIR:-/tmp}}"
# One cold Rust target/, the largest observed (macuahuitl 2026-08-26). Overridable
# so a host with a different build profile can calibrate without editing this.
NEED_MB="${TILLANDSIAS_SCRATCH_NEED_MB:-4500}"

[ -d "$SCRATCH" ] || { echo "skip:no-scratchpad"; exit 0; }

_to_mb() {  # accept 88K / 1620M / 3.2G / plain blocks, echo integer MB
    case "$1" in
        *K|*k) echo $(( ${1%[Kk]} / 1024 )) ;;
        *M|*m) echo "${1%[Mm]}" ;;
        *G|*g) awk -v v="${1%[Gg]}" 'BEGIN{printf "%d", v*1024}' ;;
        *T|*t) awk -v v="${1%[Tt]}" 'BEGIN{printf "%d", v*1048576}' ;;
        ''|*[!0-9]*) echo 0 ;;
        *) echo $(( $1 / 1024 )) ;;   # bare 1K-blocks
    esac
}

if ! command -v quota >/dev/null 2>&1; then
    # No quota tooling (macOS, most Windows lanes). Fall back to the filesystem,
    # and SAY it is the filesystem — reporting a df number as a quota headroom
    # would be the misattribution this packet's sibling cheatsheet is about.
    avail_mb="$(df -Pm "$SCRATCH" 2>/dev/null | awk 'NR==2{print $4}')"
    [ -n "$avail_mb" ] || { echo "skip:no-quota-tool"; exit 0; }
    if [ "$avail_mb" -lt "$NEED_MB" ]; then
        echo "[check-scratchpad-headroom] ${avail_mb}M free on $SCRATCH, below the ${NEED_MB}M a cold Rust target/ needs." >&2
        echo "[check-scratchpad-headroom] No quota tooling here, so this is FILESYSTEM free space, not a quota headroom." >&2
        echo "warn:scratchpad-disk-low:${avail_mb}m"
        exit 0
    fi
    echo "skip:no-quota-tool"
    exit 0
fi

# `quota -f <path>` disambiguates: a bare `quota -s` prints one row per tmpfs
# mount and they are ALL named "tmpfs", so parsing by device name picks an
# arbitrary one. Measured on lenovinha: /dev/shm, /run/user/1000 and /tmp all
# report as "tmpfs" and only one of them is the scratchpad.
_q="$(quota -s -f "$SCRATCH" 2>/dev/null | awk 'NR>2 && NF>=4 {print $2, $4; exit}')"
if [ -z "$_q" ]; then
    echo "skip:no-quota"
    exit 0
fi
used_mb="$(_to_mb "$(printf '%s' "$_q" | awk '{print $1}')")"
limit_mb="$(_to_mb "$(printf '%s' "$_q" | awk '{print $2}')")"
if [ "${limit_mb:-0}" -le 0 ]; then
    echo "skip:no-quota"
    exit 0
fi
avail_mb=$(( limit_mb - used_mb ))
[ "$avail_mb" -lt 0 ] && avail_mb=0

if [ "$avail_mb" -lt "$NEED_MB" ]; then
    df_avail="$(df -Pm "$SCRATCH" 2>/dev/null | awk 'NR==2{print $4}')"
    echo "[check-scratchpad-headroom] SCRATCHPAD QUOTA HEADROOM IS ${avail_mb}M of ${limit_mb}M." >&2
    echo "  A cold Rust target/ needs ~${NEED_MB}M (measured 2.6-4.4 GB), so a build" >&2
    echo "  here cannot succeed. Build in the checkout instead — never in the" >&2
    echo "  scratchpad (order 915-wkm2)." >&2
    if [ -n "$df_avail" ] && [ "$df_avail" -gt "$avail_mb" ]; then
        echo "  NOTE: df reports ${df_avail}M free, which OVERSTATES what you can use." >&2
        echo "  The quota binds first; df cannot see it. That gap is the whole trap." >&2
    fi
    echo "warn:scratchpad-headroom-low:${avail_mb}m-of-${limit_mb}m"
    exit 0
fi
echo "ok:scratchpad-headroom:${avail_mb}m-of-${limit_mb}m"
exit 0

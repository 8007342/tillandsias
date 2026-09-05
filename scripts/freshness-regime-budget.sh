#!/usr/bin/env bash
# @trace order:1038-d7vw
#
# freshness-regime-budget.sh — print the wall-clock budget, in milliseconds,
# that scripts/freshness-inventory.sh must meet ON THIS FILESYSTEM.
#
# WHY THE BUDGET IS NAMED BY REGIME AND NOT BY HOST (operator ruling via
# macuahuitl-fedora, 2026-09-05, on esme-windows's three-way control).
#
# One machine, one CPU, one kernel, one script, in-tree each time, with 1658
# output lines and 5288 tracked files IDENTICAL in all three arms — so no empty
# walk is hiding inside a fast number:
#
#     Git Bash / MSYS over drvfs      13,841 ms
#     inside the distro, /mnt/c (9p)  10,044 ms
#     inside the distro, native ext4      725 ms
#
# 9p/drvfs alone is 13.9x. The MSYS layer adds a further 38% and is secondary.
#
# THE TIER LABEL DOES NOT PREDICT THIS NUMBER; THE REGIME DOES. On ext4 that
# "floor-tier" N100 runs the walk in 725 ms against lenovinha's 680 ms — within
# 7% of a dual-GPU mobile workstation. This packet was misled by the tier label
# twice from OPPOSITE directions before anyone measured: an overlay hypothesis
# about lenovinha being slow, and "the floor box is slow" about esmeraldinha.
# Both wrong the same way.
#
# A SINGLE GLOBAL NUMBER CANNOT SERVE 0.7s AND 13.8s HONESTLY. Set it for ext4
# and every Windows host is permanently red; set it for drvfs and it stops
# measuring anything on Linux. Worse, a host-assigned budget is set by whichever
# host happened to file the packet — the failure two hosts walked into from
# opposite ends here. Reading the regime at runtime makes the budget select
# itself, so it is falsifiable rather than negotiated.
#
# HOW THE TWO NUMBERS ARE DERIVED, because a budget nobody can re-derive is a
# magic constant:
#
#   native (ext4, btrfs, xfs, apfs, zfs, overlay-on-native): 15000 ms, UNCHANGED.
#     It stays exactly what it was, and it stays a TREE-SIZE TRIPWIRE rather
#     than a host-power threshold — measured 725 ms and 680 ms against it, so
#     the headroom is ~20x and anything approaching it means the tree grew or a
#     linear scan over a set came back.
#
#   9p / drvfs / v9fs / cifs / MSYS: 20000 ms. The bound is TWO-SIDED and that
#     is what fixes the number rather than taste:
#       lower — it must clear the measured 13,841 ms by more than the >10%
#               swing esme observed under contention. 20000 gives 45%.
#       upper — it must stay below the 25,186 ms PRE-FIX cost, so a regression
#               back to the quadratic still trips it.
#     13.8 < B < 25.2 leaves little room to be arbitrary; 20000 sits near the
#     middle with both margins stated.
#
# THE MSYS CAVEAT, recorded by esme rather than glossed: `findmnt` DOES NOT
# EXIST under MSYS, so that arm's regime cannot be read in its own environment.
# It is inferred from the path instead (a /c/... or C:\ path under MSYS is the
# Windows volume, which arm B measured directly as 9p). Everything else in that
# arm was directly measured. An inferred regime is weaker evidence than a read
# one, and this script says which it used on its own output line so a reader
# never has to guess.
#
# Output (one line, stable, greppable):
#   freshness-budget: ms=<n> regime=<native|remote> fs=<fstype|msys-inferred|unknown> source=<findmnt|path-inference|default>
#
# An UNKNOWN regime takes the REMOTE budget deliberately. The failure we are
# avoiding is an intermittent red on a host whose regime we could not read, and
# a too-generous budget on a fast filesystem still catches the quadratic (25.2s
# pre-fix against 20s), which is the regression this budget exists to catch.

set -uo pipefail

BUDGET_NATIVE_MS=15000
BUDGET_REMOTE_MS=20000

target="${1:-.}"

fstype=""
source="default"

if command -v findmnt >/dev/null 2>&1; then
    fstype="$(findmnt -no FSTYPE -T "$target" 2>/dev/null | head -1 || true)"
    [ -n "$fstype" ] && source="findmnt"
fi

if [ -z "$fstype" ]; then
    # No findmnt: MSYS/Git Bash, or a stripped environment. Infer from the path.
    # `pwd -W` prints a Windows path under MSYS and fails elsewhere, which is a
    # positive signal for the regime rather than a guess about the OS name.
    if win="$(pwd -W 2>/dev/null)" && [ -n "$win" ]; then
        fstype="msys-inferred"
        source="path-inference"
    else
        fstype="unknown"
    fi
fi

case "$fstype" in
    # Locally-attached filesystems. overlay is included because a container
    # overlay on native storage measured as native here — the 16.7s user vs
    # 1.7s sys split on lenovinha ruled out overlay cost entirely, which is the
    # hypothesis this packet started from and disproved.
    ext2|ext3|ext4|btrfs|xfs|f2fs|zfs|apfs|hfs|overlay|tmpfs)
        regime=native; ms="$BUDGET_NATIVE_MS" ;;
    # Anything crossing a virtualisation or network boundary.
    9p|v9fs|drvfs|cifs|smb3|nfs|nfs4|fuseblk|msys-inferred)
        regime=remote; ms="$BUDGET_REMOTE_MS" ;;
    *)
        regime=remote; ms="$BUDGET_REMOTE_MS" ;;
esac

printf 'freshness-budget: ms=%s regime=%s fs=%s source=%s\n' \
    "$ms" "$regime" "$fstype" "$source"

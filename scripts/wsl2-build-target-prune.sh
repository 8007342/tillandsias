#!/usr/bin/env bash
# @trace order:667-kfyn
#
# wsl2-build-target-prune.sh — keep the WSL2 builder's distro-native cargo
# target from filling the Windows drive. Runs INSIDE the tillandsias-build
# distro; called by scripts/with-wsl2-builder.sh before every wrapped run.
#
# WHY, measured on yolanda-windows 2026-10-17: nothing ever pruned
# $CARGO_TARGET_DIR/debug. It reached 164 GB (incremental/ 86 GB, deps/ 73 GB:
# every gate's test binaries and incremental sessions, kept forever), the
# distro's ext4.vhdx grew to 251.6 GB, C: hit 0 bytes free, and the guest
# returned I/O errors mid-gate (bus errors in cargo, unreadable /usr/sbin).
# A vhdx does not shrink on its own; diskpart `compact vdisk` took it to 89 GB.
#
#   wsl2-build-target-prune.sh [<max-gb>]
#     <max-gb>  default $TILLANDSIAS_WSL2_TARGET_DEBUG_MAX_GB, else 40; "off"
#               leaves the target alone.
#
# Over the limit it removes debug/incremental first (rebuilt by the next
# compile, the cheapest thing to lose); if debug/ is still over, all of debug/.
# release/ (the plan binary the gate stamps) and the cross targets are never
# touched. Only an ABSOLUTE CARGO_TARGET_DIR outside /mnt/ is pruned: an
# in-tree target on the Windows checkout is the operator's, not the builder's.
#
# Verdicts (one line; never fails the build):
#   ok:wsl2-build-target-prune:debug=<gb>g:max=<gb>g
#   pruned:wsl2-build-target-prune:<what>:debug=<before>g-><after>g:max=<gb>g
#   skip:wsl2-build-target-prune:<why>
set -uo pipefail

MAX="${1:-${TILLANDSIAS_WSL2_TARGET_DEBUG_MAX_GB:-40}}"
T="${CARGO_TARGET_DIR:-}"
UNIT_KB="${TILLANDSIAS_WSL2_TARGET_PRUNE_UNIT_KB:-1048576}"   # fixture seam: 1 = sizes in KB
PROTECT="${TILLANDSIAS_WSL2_TARGET_PRUNE_PROTECT:-/mnt/}"   # fixture seam: the Windows-drive prefix

[ "$MAX" != "off" ] || { echo "skip:wsl2-build-target-prune:off"; exit 0; }
case "$MAX" in ''|*[!0-9]*) echo "skip:wsl2-build-target-prune:bad-max:$MAX"; exit 0 ;; esac
case "$T" in
    "$PROTECT"*) echo "skip:wsl2-build-target-prune:target-on-windows-drive"; exit 0 ;;
    /*) ;;
    *) echo "skip:wsl2-build-target-prune:no-absolute-target"; exit 0 ;;
esac
[ -d "$T/debug" ] || { echo "skip:wsl2-build-target-prune:no-debug-dir"; exit 0; }

gb() { local k; k="$(du -sk "$1" 2>/dev/null)"; k="${k%%[[:space:]]*}"; echo $(( ${k:-0} / UNIT_KB )); }

before="$(gb "$T/debug")"
[ "$before" -gt "$MAX" ] || { echo "ok:wsl2-build-target-prune:debug=${before}g:max=${MAX}g"; exit 0; }
what="incremental"
rm -rf "${T:?}/debug/incremental"
if [ "$(gb "$T/debug")" -gt "$MAX" ]; then
    what="debug"
    rm -rf "${T:?}/debug"
fi
after=0
[ ! -d "$T/debug" ] || after="$(gb "$T/debug")"
echo "pruned:wsl2-build-target-prune:${what}:debug=${before}g->${after}g:max=${MAX}g"

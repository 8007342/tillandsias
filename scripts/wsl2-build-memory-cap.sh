#!/usr/bin/env bash
# @trace order:667-kfyn
#
# wsl2-build-memory-cap.sh — put the CALLING shell (and so every process the
# build starts) into one cgroup-v2 group with a soft memory cap (memory.high),
# inside the tillandsias-build WSL2 distro. Called by scripts/with-wsl2-builder.sh
# at the front of every wrapped run.
#
# WHY, measured on yolanda-windows 2026-10-17 (15.16 GiB host, memory=8GB):
# nothing OOMs inside the guest. A build.sh --check held 0.8-1.1 GB of process
# memory while the guest's PAGE CACHE grew to 5.2 GB; WSL2 keeps that cache
# resident, vmmemWSL reached 6.75 GB and Windows fell to 1.5 GB free, under the
# 1 GiB at which Claude Code reaps background tasks (and the gate with them).
# Moving the live build into a group with memory.high=3G: within ~10 s
# vmmemWSL fell to 4.1 GB and Windows rose to 3.0 GB free; for the rest of the
# 46-min run Windows stayed >= 3.6 GB free, vmmemWSL peaked at 4.4 GB, and
# memory.events counted oom=0 (high=24054: the kernel reclaimed the group's
# cache at the cap instead of growing it). Page cache is charged to the group
# that reads it, so the cap bounds the cache the build creates, and freed
# pages go back to Windows through free page reporting.
#
# memory.high THROTTLES AND RECLAIMS, it never kills: a build that truly needs
# more runs slower rather than dying. One shared group, so two concurrent
# builds share one cap, which is the point: the pressure is on the host.
#
#   wsl2-build-memory-cap.sh [<cap>]
#     <cap>  bytes or K/M/G suffix; default $TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH,
#            else 3G. "off" leaves the caller where it is.
#
# Verdicts (one line, stderr-quiet; never fails the build):
#   ok:wsl2-build-memory-cap:<group>:high=<bytes>
#   skip:wsl2-build-memory-cap:off
#   skip:wsl2-build-memory-cap:<why>   no cgroup v2 / no memory controller / not writable
set -uo pipefail

CAP="${1:-${TILLANDSIAS_WSL2_BUILD_MEMORY_HIGH:-3G}}"
ROOT_CG="${TILLANDSIAS_WSL2_CGROUP_ROOT:-/sys/fs/cgroup}"   # fixture seam
GROUP="$ROOT_CG/tillandsias-build"
TARGET_PID="${TILLANDSIAS_WSL2_CGROUP_PID:-$PPID}"           # fixture seam

[ "$CAP" != "off" ] || { echo "skip:wsl2-build-memory-cap:off"; exit 0; }
[ -f "$ROOT_CG/cgroup.controllers" ] || { echo "skip:wsl2-build-memory-cap:no-cgroup-v2"; exit 0; }
grep -qw memory "$ROOT_CG/cgroup.controllers" || { echo "skip:wsl2-build-memory-cap:no-memory-controller"; exit 0; }
if ! grep -qw memory "$ROOT_CG/cgroup.subtree_control" 2>/dev/null; then
    echo +memory > "$ROOT_CG/cgroup.subtree_control" 2>/dev/null \
        || { echo "skip:wsl2-build-memory-cap:cannot-enable-memory-controller"; exit 0; }
fi
mkdir -p "$GROUP" 2>/dev/null || { echo "skip:wsl2-build-memory-cap:cannot-create-group"; exit 0; }
echo "$CAP" > "$GROUP/memory.high" 2>/dev/null || { echo "skip:wsl2-build-memory-cap:bad-cap:$CAP"; exit 0; }
echo "$TARGET_PID" > "$GROUP/cgroup.procs" 2>/dev/null || { echo "skip:wsl2-build-memory-cap:cannot-join:$TARGET_PID"; exit 0; }
echo "ok:wsl2-build-memory-cap:${GROUP##*/}:high=$(cat "$GROUP/memory.high")"

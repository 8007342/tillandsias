#!/usr/bin/env bash
# measure-forge-spill.sh — does a forge's tmpfs spill to swap beat a disk volume?
# @trace order:1378-7w2p
#
# PROTOCOL: plan/issues/forge-memory-swap-architecture-design-2026-09-26.md §7.2/§7.3.
# A forge container with memory.max = M writes W MiB of files into
# /home/forge/src (BACKING=tmpfs: the HOT tier; BACKING=volume: a named podman
# volume, the COLD control), then re-reads them in a SHUFFLED order. Recorded:
# write and read wall times, memory.swap.peak, memory.peak, memory.events.
# The falsifiable claim: tmpfs + swap beats the disk volume at W = 2M. If it
# does not, the HOT budget must be sized to stay resident.
#
# DATA IS INCOMPRESSIBLE (/dev/urandom): zram compresses, so real source trees
# spill cheaper than this. This is the conservative bound, and it is stated.
#
# Swap ceiling: rootless crun writes --memory-swap to memory.swap.max
# LITERALLY (measured: 1g/1g -> swap.max 1 GiB, 1g/2g -> 2 GiB, 1g/0 -> 0),
# so --swap-mib sets memory.swap.max directly; 0 is the §7.3 no-swap control.
#
# OUTPUT: measure:forge-spill:backing=<>:M=<>:W=<>:swap_max=<>:write_ms=<>:read_ms=<>:
#   swap_peak_mib=<>:memory_peak_mib=<>:oom=<>:oom_kill=<>:high=<>:max=<>:rc=<>:verdict=<>
set -uo pipefail

m_mib=1024; w_mib=512; swap_mib=2048; backing=tmpfs; image=""; guard=1200
while [ $# -gt 0 ]; do
    case "$1" in
        --memory-mib) m_mib="$2"; shift 2 ;;
        --write-mib) w_mib="$2"; shift 2 ;;
        --swap-mib) swap_mib="$2"; shift 2 ;;
        --backing) backing="$2"; shift 2 ;;
        --image) image="$2"; shift 2 ;;
        --guard-mib) guard="$2"; shift 2 ;;
        *) echo "could-not-run:unknown-argument:$1"; exit 3 ;;
    esac
done
[ -n "$image" ] || { echo "could-not-run:usage: --image <versioned tag or digest> is required"; exit 3; }
podman image inspect "$image" >/dev/null 2>&1 || { echo "could-not-run:no-such-image:$image"; exit 3; }
case "$backing" in tmpfs|volume) ;; *) echo "could-not-run:backing must be tmpfs|volume"; exit 3 ;; esac

name="forge-spill-$$"; vol="forge-spill-vol-$$"
cleanup() { podman rm -f -t 0 "$name" >/dev/null 2>&1; podman volume rm -f "$vol" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

if [ "$backing" = tmpfs ]; then
    # size cap well above W so the cgroup, not the mount, is what binds
    mnt=(--tmpfs "/home/forge/src:rw,size=$(( w_mib * 2 + 256 ))m,mode=1777")
else
    podman volume create "$vol" >/dev/null || { echo "could-not-run:volume"; exit 3; }
    mnt=(-v "$vol:/home/forge/src:Z")
fi
podman run -d --name "$name" --memory="${m_mib}m" --memory-swap="$(( m_mib + swap_mib ))m" \
    --userns=keep-id "${mnt[@]}" --entrypoint sleep "$image" infinity >/dev/null \
    || { echo "could-not-run:podman-run"; exit 3; }
C="/sys/fs/cgroup$(podman inspect --format '{{.State.CgroupPath}}' "$name")"
# set the swap ceiling exactly (crun's literal mapping above); refuse if we cannot
echo "$(( swap_mib * 1048576 ))" > "$C/memory.swap.max" 2>/dev/null \
    || { echo "could-not-run:cannot-set-swap-max:$C"; exit 3; }
[ "$(cat "$C/memory.swap.max")" = "$(( swap_mib * 1048576 ))" ] \
    || { echo "could-not-run:swap-max-not-applied:$(cat "$C/memory.swap.max")"; exit 3; }

files=$(( (w_mib + 63) / 64 ))
guarded() {  # run a podman exec, killing the container if the host runs short
    "$@" & local p=$!
    while kill -0 "$p" 2>/dev/null; do
        a=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
        if [ "$a" -lt "$guard" ]; then echo "aborted:host-guard:avail=${a}mib" > "$C.guard" 2>/dev/null; podman kill "$name" >/dev/null 2>&1; guard_hit=1; fi
        sleep 1
    done
    wait "$p"
}
# NOT $EPOCHREALTIME: its decimal separator follows the LOCALE (a comma under
# fr_FR on yoga), and stripping "." from "1790393686,018710" made bash
# arithmetic fabricate 4-16 ms for multi-GiB writes (and one negative). Every
# timing of that first matrix was discarded. date +%s%N is locale-free.
ms() { echo $(( $(date +%s%N) / 1000000 )); }
guard_hit=0
# Timed INSIDE the container around exactly the work: the host guard polls
# once a second, so host-side timing was quantised to whole seconds (1007 ms /
# 1008 ms for a 128 MiB probe). The exec prints its own elapsed ns.
guarded podman exec "$name" sh -c "cd /home/forge/src && s=\$(date +%s%N) && for i in \$(seq 1 $files); do head -c 67108864 /dev/urandom > f\$i || exit 1; done && sync && e=\$(date +%s%N) && echo \$(( (e - s) / 1000000 )) > /tmp/w.ms" ; wrc=$?
write_ms=$(podman exec "$name" cat /tmp/w.ms 2>/dev/null || echo unmeasured)
rrc=1; read_ms=0
if [ "$wrc" = 0 ]; then
    guarded podman exec "$name" sh -c 'cd /home/forge/src && s=$(date +%s%N) && ls | shuf | while read -r f; do cat "$f" > /dev/null || exit 1; done && e=$(date +%s%N) && echo $(( (e - s) / 1000000 )) > /tmp/r.ms'; rrc=$?
    read_ms=$(podman exec "$name" cat /tmp/r.ms 2>/dev/null || echo unmeasured)
fi
mib() { echo $(( ${1:-0} / 1048576 )); }
ev() { awk -v k="$1" '$1 == k { print $2 }' "$C/memory.events" 2>/dev/null; }
sp=$(cat "$C/memory.swap.peak" 2>/dev/null || echo 0); mp=$(cat "$C/memory.peak" 2>/dev/null || echo 0)
oom=$(ev oom); ok=$(ev oom_kill); hi=$(ev high); mx=$(ev max)
if [ "$guard_hit" = 1 ]; then v="aborted:host-guard"
elif [ "$wrc" != 0 ]; then v="write-failed:rc=$wrc"
elif [ "$rrc" != 0 ]; then v="read-failed:rc=$rrc"
else v=ok; fi
echo "measure:forge-spill:backing=$backing:M=${m_mib}:W=${w_mib}:swap_max=${swap_mib}:write_ms=$write_ms:read_ms=$read_ms:swap_peak_mib=$(mib "$sp"):memory_peak_mib=$(mib "$mp"):oom=${oom:-?}:oom_kill=${ok:-?}:high=${hi:-?}:max=${mx:-?}:rc=$wrc/$rrc:verdict=$v"

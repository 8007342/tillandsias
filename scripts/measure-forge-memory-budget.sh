#!/usr/bin/env bash
# measure-forge-memory-budget.sh — working-set peaks of a forge cargo build per
# CARGO_BUILD_JOBS, read from the container's own cgroup.
# @trace order:1378-7w2p
# @trace order:1375-xxzj (the budget these numbers retune)
# @trace order:1372-igkr (pids.peak and ulimit -u: EAGAIN on fork can be either)
#
# PROTOCOL: plan/issues/forge-memory-swap-architecture-design-2026-09-26.md §7.1.
# One run = one CARGO_BUILD_JOBS value:
#   1. a DETACHED forge container (sleep) with --memory/--memory-swap, so the
#      cgroup outlives the build and its *.peak files can be read afterwards;
#   2. a fresh `git clone --local` of HEAD bind-mounted at /home/forge/src,
#      with CARGO_TARGET_DIR inside it (a cold build every run: comparable);
#   3. `podman exec` of `cargo build --workspace --all-targets -j N`;
#   4. the host polls the cgroup once a second and records the maxima;
#   5. memory.peak, memory.swap.peak, pids.peak and memory.events are read
#      from the cgroup BEFORE the container is removed.
#
# DEVIATION FROM §7.1, stated: the build is `cargo build --workspace
# --all-targets`, not `./build.sh --check`. The peak the budget needs is the
# compiler's; --check adds ~20 minutes of shell fixtures that do not approach it.
#
# HOST GUARD: a floor host can be pushed into thrashing by a -j nproc build,
# which would take the operator's session down with it. The poller kills the
# container if host MemAvailable drops below --guard-mib (default 1200) and
# the run is reported as `aborted:host-guard`, never as a peak.
#
# OUTPUT: one line per run on stdout (the rest is on stderr):
#   measure:forge-memory:jobs=<n>:mem_max=<M>:swap_max=<S>:rc=<rc>:wall_s=<s>:
#     memory_peak_mib=<>:swap_peak_mib=<>:pids_peak=<>:poll_mem_max_mib=<>:
#     poll_swap_max_mib=<>:poll_anon_max_mib=<>:file_at_anon_max_mib=<>:oom=<n>:oom_kill=<n>:high=<n>:max=<n>:ulimit_u=<>:
#     host_min_avail_mib=<>:verdict=<ok|build-failed|aborted:host-guard|...>
# Regime line first: host, kernel, nproc, RAM, swap devices, swappiness.
#
# SPILL MODE (--spill W1,W2,..., MiB; §7.2), added 2026-11-01 by lenovinha:
# under memory.max = --spill-mem MiB, write W MiB of RANDOM bytes in 64 MiB
# files into /spill, then read them back in shuffled order, timing each phase.
# /spill is a tmpfs (pages charged to the container, spilling to swap) and,
# as the control, a podman volume on disk. Random bytes are zram's worst case
# (incompressible); real build trees compress, so tmpfs+zram numbers are a
# floor. One more control run writes 2M into a tmpfs with memory.swap.max=0
# and must OOM at about M. memory.swap.max is written EXACTLY through
# --cgroup-conf (see crates/tillandsias-core/src/forge_budget.rs on
# --memory-swap). --spill-payload <dir> replaces the random bytes with REAL
# files from <dir> (e.g. a target/debug/deps tree), cut into the same 64 MiB
# chunks; the first 4 are copied in cyclically with dd, so the run shows a
# real build's compressibility rather than zram's worst. The payload's
# compressibility is reported on its own line as payload=<dir>:
# payload_zstd1_ratio=<x>:zram_alg=<alg>. Output, one line per run:
#   measure:forge-spill:backing=<tmpfs|volume>:mem_max_mib=<M>:swap_max_mib=<S>:
#     w_mib=<W>:write_ms=<>:read_ms=<>:memory_peak_mib=<>:swap_peak_mib=<>:
#     high=<n>:max=<n>:oom=<n>:oom_kill=<n>:host_min_avail_mib=<>:verdict=<>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

jobs=4; mem=8g; swap=16g; guard=1200; image=""; spill=""; spill_mem=2048; spill_swap=4096; spill_payload=""
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) jobs="$2"; shift 2 ;;
        --memory) mem="$2"; shift 2 ;;
        --memory-swap) swap="$2"; shift 2 ;;
        --guard-mib) guard="$2"; shift 2 ;;
        --image) image="$2"; shift 2 ;;
        --spill) spill="$2"; shift 2 ;;
        --spill-mem) spill_mem="$2"; shift 2 ;;
        --spill-swap) spill_swap="$2"; shift 2 ;;
        --spill-payload) spill_payload="$2"; shift 2 ;;
        *) echo "could-not-run:unknown-argument:$1"; exit 3 ;;
    esac
done
command -v podman >/dev/null 2>&1 || { echo "could-not-run:no-podman"; exit 3; }
# NO DEFAULT IMAGE: a mutable tag would not say which image produced a number
# (and check-container-bases refuses one). Name a versioned tag or a digest;
# the regime line records the resolved image ID either way.
[ -n "$image" ] || { echo "could-not-run:usage: --image <versioned tag or digest> is required"; exit 3; }
image_id="$(podman image inspect --format '{{.Id}}' "$image" 2>/dev/null)" \
    || { echo "could-not-run:no-such-image:$image"; exit 3; }

mib() { echo $(( ${1:-0} / 1048576 )); }
avail_mib() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }

echo "regime:host=$(hostname -s):kernel=$(uname -r):nproc=$(nproc):mem_total_mib=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo):swap=$(swapon --noheadings --show=NAME,TYPE,SIZE 2>/dev/null | tr -s ' ' ',' | paste -sd';'):swappiness=$(cat /proc/sys/vm/swappiness):image=$image:image_id=${image_id:0:12}"

if [ -n "$spill" ]; then
    now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
    sname=""; svol=""
    spill_cleanup() {
        [ -n "$sname" ] && podman rm -f "$sname" >/dev/null 2>&1
        [ -n "$svol" ] && podman volume rm -f "$svol" >/dev/null 2>&1
        sname=""; svol=""
    }
    trap spill_cleanup EXIT INT TERM
    # spill_run <backing> <w_mib> <swap_max_mib>
    spill_run() {
        local backing="$1" w="$2" smax="$3" mount n wt rt rc verdict="" a minavail=999999
        sname="forge-spill-$$-$backing-$w-$smax"
        if [ "$backing" = tmpfs ]; then
            mount="--mount=type=tmpfs,destination=/spill,tmpfs-size=$(( w * 2 ))m"
        else
            svol="forge-spill-vol-$$-$w"
            podman volume create "$svol" >/dev/null || { echo "could-not-run:volume-create"; return 3; }
            mount="--volume=$svol:/spill"
        fi
        local pmount=""
        [ -n "$pdir" ] && pmount="--volume=$pdir:/payload:ro,z"
        podman run -d --name "$sname" --memory="${spill_mem}m" --memory-swap=-1 \
            --cgroup-conf=memory.swap.max=$(( smax * 1048576 )) "$mount" ${pmount:+"$pmount"} \
            --entrypoint sleep "$image" infinity >/dev/null || { echo "could-not-run:podman-run"; return 3; }
        local C; C="/sys/fs/cgroup$(podman inspect --format '{{.State.CgroupPath}}' "$sname" 2>/dev/null)"
        [ -r "$C/memory.peak" ] || { echo "could-not-run:cgroup-unreadable:$C"; spill_cleanup; return 3; }
        n=$(( w / 64 ))
        # Host guard: a watcher kills the container if MemAvailable drops
        # below --guard-mib, and leaves the minimum in a file.
        ( m=999999; while podman container exists "$sname" 2>/dev/null; do
              a=$(avail_mib); [ "$a" -lt "$m" ] && m=$a && echo "$m" > "$ROOT/target/forge-spill-$$.min"
              if [ "$a" -lt "$guard" ]; then echo guard > "$ROOT/target/forge-spill-$$.guard"; podman kill "$sname" >/dev/null 2>&1; break; fi
              sleep 1; done ) &
        local wpid=$!
        local t0; t0=$(now_ms)
        if [ -n "$pdir" ]; then
            # dd, not cp: on btrfs cp reflinks and writes no data (measured
            # 2026-11-01: 4 GiB "written" to the volume in 168 ms). Cycle the
            # first 4 chunks (256 MiB, stays cached): re-reading a large
            # payload charges its page cache to this same cgroup, and with a
            # low swappiness the kernel evicts it instead of swapping the
            # tmpfs, so the run measures read thrash, not the spill (same
            # date: 25 min, then SIGKILL, 312 MiB swapped).
            podman exec "$sname" sh -c 'i=0; while [ $i -lt '"$n"' ]; do dd if=/payload/c000$((i % 4)) of=/spill/c$i bs=1M status=none || exit 1; i=$((i+1)); done; sync'
        else
            podman exec "$sname" sh -c 'i=0; while [ $i -lt '"$n"' ]; do dd if=/dev/urandom of=/spill/c$i bs=1M count=64 status=none || exit 1; i=$((i+1)); done; sync'
        fi
        rc=$?; wt=$(( $(now_ms) - t0 )); rt=-1
        if [ "$rc" = 0 ]; then
            t0=$(now_ms)
            podman exec "$sname" sh -c 'for f in $(ls /spill | shuf); do cat /spill/$f > /dev/null || exit 1; done'
            rc=$?; rt=$(( $(now_ms) - t0 ))
        fi
        local peak speak; peak=$(cat "$C/memory.peak" 2>/dev/null || echo 0); speak=$(cat "$C/memory.swap.peak" 2>/dev/null || echo 0)
        sev() { awk -v k="$1" '$1 == k { print $2 }' "$C/memory.events" 2>/dev/null; }
        local high mx oom oomk; high=$(sev high); mx=$(sev max); oom=$(sev oom); oomk=$(sev oom_kill)
        spill_cleanup
        wait "$wpid" 2>/dev/null
        [ -r "$ROOT/target/forge-spill-$$.min" ] && minavail=$(cat "$ROOT/target/forge-spill-$$.min")
        if [ -e "$ROOT/target/forge-spill-$$.guard" ]; then verdict="aborted:host-guard"
        elif [ "$rc" = 0 ]; then verdict=ok
        elif [ "${oomk:-0}" -gt 0 ]; then verdict="oom-killed:rc=$rc"
        else verdict="failed:rc=$rc"; fi
        rm -f "$ROOT/target/forge-spill-$$.min" "$ROOT/target/forge-spill-$$.guard"
        echo "measure:forge-spill:payload=$( [ -n "$pdir" ] && echo real || echo random ):backing=$backing:mem_max_mib=$spill_mem:swap_max_mib=$smax:w_mib=$w:write_ms=$wt:read_ms=$rt:memory_peak_mib=$(mib "$peak"):swap_peak_mib=$(mib "$speak"):high=${high:-?}:max=${mx:-?}:oom=${oom:-?}:oom_kill=${oomk:-?}:host_min_avail_mib=$minavail:verdict=$verdict"
        [ "$verdict" != "aborted:host-guard" ]
    }
    # A real payload: concatenate files from the tree until the largest W is
    # covered, cut into 64 MiB chunks, bind-mounted read-only at /payload.
    pdir=""
    if [ -n "$spill_payload" ]; then
        [ -d "$spill_payload" ] || { echo "could-not-run:no-payload-dir:$spill_payload"; exit 3; }
        wmax=0; for w in ${spill//,/ }; do [ "$w" -gt "$wmax" ] && wmax=$w; done
        [ $(( spill_mem * 2 )) -gt "$wmax" ] && wmax=$(( spill_mem * 2 ))
        pdir="$(mktemp -d "$ROOT/target/forge-spill-payload.XXXXXX")" || { echo "could-not-run:no-payload-workdir"; exit 3; }
        find "$spill_payload" -type f -size +0 -print0 | sort -z \
            | xargs -0 cat 2>/dev/null | head -c $(( wmax * 1048576 )) \
            | split -b 64M -d -a 4 - "$pdir/c"
        # mktemp -d is 0700; the container's forge user must read the chunks.
        chmod -R a+rX "$pdir"
        have=$(du -sm "$pdir" | cut -f1)
        [ "$have" -ge "$wmax" ] || { echo "could-not-run:payload-too-small:${have}<${wmax}mib"; rm -rf "$pdir"; exit 3; }
        ratio="?"
        if command -v zstd >/dev/null 2>&1; then
            raw=$(stat -c %s "$pdir/c0000"); packed=$(zstd -1 -c "$pdir/c0000" | wc -c)
            ratio=$(awk -v r="$raw" -v p="$packed" 'BEGIN { printf "%.2f", r / p }')
        fi
        echo "payload=$spill_payload:payload_zstd1_ratio=$ratio:zram_alg=$(grep -o '\[[a-z0-9-]*\]' /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')"
        trap 'spill_cleanup; rm -rf "$pdir"' EXIT INT TERM
    fi
    for w in ${spill//,/ }; do
        spill_run tmpfs "$w" "$spill_swap" || exit 1
        spill_run volume "$w" "$spill_swap" || exit 1
    done
    # Control: no swap allowance; writing 2M into tmpfs must OOM near M.
    spill_run tmpfs $(( spill_mem * 2 )) 0 || exit 1
    exit 0
fi

WORK="$(mktemp -d "$ROOT/target/forge-memory.XXXXXX")" || { echo "could-not-run:no-workdir"; exit 3; }
name="forge-mem-$$"
cleanup() { podman rm -f "$name" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

git -C "$ROOT" clone -q --local --no-hardlinks "$ROOT" "$WORK/src" || { echo "could-not-run:clone"; exit 3; }
# The router sidecar is a gitignored BUILD ARTIFACT that tillandsias-headless's
# build.rs include_bytes!()s; build.sh stages it before every cargo call, so a
# fresh clone lacks it (second run: build.rs refused, rc=101 at 50 s). Copy the
# checkout's staged copy, exactly what the gate would have staged; refuse if
# there is none rather than measure a build that stops at build.rs.
for f in $(git -C "$ROOT" ls-files --others --ignored --exclude-standard images/router/); do
    mkdir -p "$WORK/src/$(dirname "$f")" && cp -a "$ROOT/$f" "$WORK/src/$f"
done
[ -n "$(git -C "$ROOT" ls-files --others --ignored --exclude-standard images/router/)" ] \
    || { echo "could-not-run:no-staged-sidecar: run bash scripts/build-sidecar.sh first"; exit 3; }
chmod -R a+rwX "$WORK/src"

# CARGO_HOME: the image's /usr/local/cargo is not writable by the forge user
# (first run: "failed to create directory .../registry/cache", rc=101). One
# persistent home under target/ is shared by every run, and the crates are
# fetched BEFORE the measured build, so a peak never includes a download.
CH="$ROOT/target/forge-memory-cargo-home"
mkdir -p "$CH" && chmod a+rwX "$CH"
podman run -d --name "$name" --memory="$mem" --memory-swap="$swap" \
    --userns=keep-id -v "$WORK/src:/home/forge/src:Z" -v "$CH:/home/forge/.cargo-home:Z" \
    -e CARGO_HOME=/home/forge/.cargo-home -w /home/forge/src \
    --entrypoint sleep "$image" infinity >/dev/null || { echo "could-not-run:podman-run"; exit 3; }
cg="$(podman inspect --format '{{.State.CgroupPath}}' "$name" 2>/dev/null)"
C="/sys/fs/cgroup${cg}"
[ -r "$C/memory.current" ] || { echo "could-not-run:cgroup-unreadable:$C"; exit 3; }
ulimit_u="$(podman exec "$name" sh -c 'ulimit -u' 2>/dev/null)"

podman exec "$name" cargo fetch >"$WORK/fetch.log" 2>&1 || { tail -3 "$WORK/fetch.log" >&2; echo "could-not-run:cargo-fetch"; exit 3; }

start=$SECONDS
podman exec -e CARGO_BUILD_JOBS="$jobs" -e CARGO_TARGET_DIR=/home/forge/src/target "$name" \
    cargo build --workspace --all-targets -j "$jobs" >"$WORK/build.log" 2>&1 &
bpid=$!

pm=0; ps=0; pa=0; pf_at_pa=0; minavail=999999; verdict=""
while kill -0 "$bpid" 2>/dev/null; do
    m=$(cat "$C/memory.current" 2>/dev/null || echo 0)
    s=$(cat "$C/memory.swap.current" 2>/dev/null || echo 0)
    [ "$m" -gt "$pm" ] && pm=$m
    [ "$s" -gt "$ps" ] && ps=$s
    # memory.current (and memory.peak) COUNT PAGE CACHE — everything cargo
    # writes to target/. The working set a budget must hold resident is the
    # ANON part; file pages are reclaimable. Poll both from memory.stat.
    read -r an fi < <(awk '$1 == "anon" { a = $2 } $1 == "file" { f = $2 } END { print a + 0, f + 0 }' "$C/memory.stat" 2>/dev/null)
    if [ "${an:-0}" -gt "$pa" ]; then pa=$an; pf_at_pa=${fi:-0}; fi
    a=$(avail_mib); [ "$a" -lt "$minavail" ] && minavail=$a
    if [ "$a" -lt "$guard" ]; then
        verdict="aborted:host-guard:avail=${a}mib"
        podman kill "$name" >/dev/null 2>&1
        break
    fi
    sleep 1
done
wait "$bpid"; rc=$?
wall=$(( SECONDS - start ))

peak=$(cat "$C/memory.peak" 2>/dev/null || echo "")
speak=$(cat "$C/memory.swap.peak" 2>/dev/null || echo "")
pids=$(cat "$C/pids.peak" 2>/dev/null || echo "")
ev() { awk -v k="$1" '$1 == k { print $2 }' "$C/memory.events" 2>/dev/null; }
oom=$(ev oom); oomk=$(ev oom_kill); high=$(ev high); mx=$(ev max)

if [ -z "$verdict" ]; then
    if [ "$rc" = 0 ]; then verdict=ok; else verdict="build-failed:rc=$rc"; fi
fi
[ "$verdict" = ok ] || tail -5 "$WORK/build.log" >&2
echo "measure:forge-memory:jobs=$jobs:mem_max=$mem:swap_max=$swap:rc=$rc:wall_s=$wall:memory_peak_mib=$( [ -n "$peak" ] && mib "$peak" || echo unreadable ):swap_peak_mib=$( [ -n "$speak" ] && mib "$speak" || echo unreadable ):pids_peak=${pids:-unreadable}:poll_mem_max_mib=$(mib $pm):poll_swap_max_mib=$(mib $ps):poll_anon_max_mib=$(mib $pa):file_at_anon_max_mib=$(mib $pf_at_pa):oom=${oom:-?}:oom_kill=${oomk:-?}:high=${high:-?}:max=${mx:-?}:ulimit_u=${ulimit_u:-?}:host_min_avail_mib=$minavail:verdict=$verdict"
[ "$verdict" = ok ]

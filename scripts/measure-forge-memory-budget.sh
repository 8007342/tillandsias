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
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

jobs=4; mem=8g; swap=16g; guard=1200; image="localhost/tillandsias-forge:latest"
while [ $# -gt 0 ]; do
    case "$1" in
        --jobs) jobs="$2"; shift 2 ;;
        --memory) mem="$2"; shift 2 ;;
        --memory-swap) swap="$2"; shift 2 ;;
        --guard-mib) guard="$2"; shift 2 ;;
        --image) image="$2"; shift 2 ;;
        *) echo "could-not-run:unknown-argument:$1"; exit 3 ;;
    esac
done
command -v podman >/dev/null 2>&1 || { echo "could-not-run:no-podman"; exit 3; }

mib() { echo $(( ${1:-0} / 1048576 )); }
avail_mib() { awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo; }

echo "regime:host=$(hostname -s):kernel=$(uname -r):nproc=$(nproc):mem_total_mib=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo):swap=$(swapon --noheadings --show=NAME,TYPE,SIZE 2>/dev/null | tr -s ' ' ',' | paste -sd';'):swappiness=$(cat /proc/sys/vm/swappiness):image=$image"

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

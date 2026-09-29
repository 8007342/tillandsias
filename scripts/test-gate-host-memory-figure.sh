#!/usr/bin/env bash
# @trace order:1471-8ydv
#
# A WSL2 gate gets its memory floor back: with-wsl2-builder.sh samples the
# Windows host's MemFree on the Windows side and exports it as
# TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB. build.sh's floor consumer hands it to
# check-gate-memory-floor.sh through --meminfo-from, the floor's judged path.
#
# REGIME: hermetic. Both real blocks are cut from the shipped files (the
# wrapper between its BEGIN and END markers, build.sh's consumer between
# `_mem_rc=0` and its `esac`, the same cut test-gate-memory-floor-consumer.sh
# makes). They are driven with the REAL floor script and synthetic meminfo.
#
#   1  sampler: a host meminfo with MemFree exports the figure (in kB)
#   2  sampler: a figure already set is not overwritten
#   3  consumer: a STARVED host figure stops the gate (rc 1, refused line)
#   4  consumer: a healthy host figure proceeds with ok from THAT figure
#   5  consumer: a non-numeric figure is ignored and no temp meminfo is left
#   6  end to end: sampler output feeds the consumer, and the floor judges the
#      host's number, not the guest's
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAP="$ROOT/scripts/with-wsl2-builder.sh"
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

sed -n '/^# BEGIN-HOST-MEMORY-SAMPLE$/,/^# END-HOST-MEMORY-SAMPLE$/p' "$WRAP" > "$W/sample.sh"
sed -n '/^    _mem_rc=0$/,/^    esac$/p' "$ROOT/build.sh" > "$W/consumer.sh"
if ! grep -q 'END-HOST-MEMORY-SAMPLE' "$W/sample.sh" || ! grep -q 'TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB' "$W/consumer.sh"; then
    bad "could not cut the sampler or the consumer block from the shipped files"
    echo "violation:gate-host-memory-figure:0/1"; exit 1
fi

printf 'MemTotal:       16000000 kB\nMemFree:         4465888 kB\n' > "$W/host-meminfo"

# sample <meminfo> [preset] -> prints the exported figure (or <unset>)
sample() {
    env -u TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB ${2:+TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB="$2"} \
        TILLANDSIAS_WSL2_HOST_MEMINFO="$1" bash -c '. "$0"; printf "%s\n" "${TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB:-<unset>}"' "$W/sample.sh"
}
# drive <figure> -> runs the consumer against the REAL floor, prints output; rc = its rc
drive() {
    local d; d="$(mktemp -d "$W/run.XXXXXX")"
    {
        printf 'set -euo pipefail\nSCRIPT_DIR=%q\nTMPDIR=%q\n' "$ROOT" "$d"
        printf '_info() { echo "INFO: $*"; }\n_warn() { echo "WARN: $*"; }\n_error() { echo "ERROR: $*"; }\n'
        printf '. %q\necho "consumer-block-completed"\n' "$W/consumer.sh"
    } > "$d/driver.sh"
    TILLANDSIAS_GATE_HOST_MEMAVAILABLE_KB="$1" TILLANDSIAS_GATE_MEMORY_FLOOR_MB=1024 bash "$d/driver.sh" > "$d/out" 2>&1
    local rc=$?
    cat "$d/out"
    echo "leftover=$(find "$d" -name 'gate-host-meminfo.*' | wc -l | tr -d ' ')"
    return "$rc"
}

# 1
v="$(sample "$W/host-meminfo")"
[ "$v" = 4465888 ] && ok "arm 1: the sampler exports the host's MemFree ($v kB)" || bad "arm 1: sampler exported [$v], want 4465888"
# 2
v="$(sample "$W/host-meminfo" 777)"
[ "$v" = 777 ] && ok "arm 2: a figure already set is kept" || bad "arm 2: preset overwritten -> [$v]"
# 3
out="$(drive 200000)"; rc=$?
case "$rc:$out" in
    1:*refused:gate:insufficient-memory*) ok "arm 3: a starved host figure stops the gate (rc 1)" ;;
    *) bad "arm 3: starved host figure did not stop the gate (rc=$rc): $out" ;;
esac
# 4
out="$(drive 8000000)"; rc=$?
case "$rc:$out" in
    0:*"INFO: ok:gate-memory:7812MB"*consumer-block-completed*) ok "arm 4: a healthy host figure proceeds, judged from it (7812MB)" ;;
    *) bad "arm 4: healthy host figure (rc=$rc): $out" ;;
esac
# 5
out="$(drive abc)"; rc=$?
case "$out" in
    *gate-host-meminfo*) bad "arm 5: a non-numeric figure was used: $out" ;;
    *leftover=0*) ok "arm 5: a non-numeric figure is ignored, no temp meminfo left (rc=$rc)" ;;
    *) bad "arm 5: $out" ;;
esac
# 6
printf 'MemTotal:       16000000 kB\nMemFree:          300000 kB\n' > "$W/host-starved"
fig="$(sample "$W/host-starved")"
out="$(drive "$fig")"; rc=$?
case "$rc:$out" in
    1:*"refused:gate:insufficient-memory (292MB available"*leftover=0*) ok "arm 6: end to end, the host's 292MB is judged and refused, temp file removed" ;;
    *) bad "arm 6: end to end (fig=$fig rc=$rc): $out" ;;
esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:gate-host-memory-figure:$pass/$total"; exit 0; fi
echo "violation:gate-host-memory-figure:$pass/$total"; exit 1

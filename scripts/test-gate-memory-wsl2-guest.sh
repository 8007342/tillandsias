#!/usr/bin/env bash
# @trace order:1337-7jr5
#
# Inside a WSL2 guest, /proc/meminfo is the utility VM's memory, not the
# Windows host's that reaps the gate, so check-gate-memory-floor.sh must not
# print ok:gate-memory from it (measured on yolanda 2026-09-21: guest ok at
# 5578MB while the host was at 28.7%, and at 10.8% earlier that hour).
#
# REGIME: hermetic. The kernel identity comes through the
# TILLANDSIAS_GATE_MEMORY_OSRELEASE seam and the host figure through
# --meminfo-from, so every arm runs the same on Linux, WSL2, MSYS and macOS.
#
#   1  WSL2 guest, default read -> could-not-run:...wsl2-guest-meminfo-is-not-the-host,
#      last line skip:, rc 3, and NO ok:gate-memory line
#   2  WSL2 guest, host figure via --meminfo-from (healthy) -> judged: ok, rc 0
#   3  WSL2 guest, host figure via --meminfo-from (starved) -> still REFUSED, rc 1
#   4  native kernel, default read -> the WSL2 refusal does not appear
#      (native behaviour unchanged)
#
# Pre-fix: arm 1 FAILS, the check prints ok:gate-memory from the guest's own
# meminfo whenever the guest has more than the floor available.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOOR="$ROOT/scripts/check-gate-memory-floor.sh"
[ -f "$FLOOR" ] || { echo "skip:gate-memory-wsl2-guest:absent"; exit 0; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { printf 'ok:   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail+1)); }

printf '%s\n' '5.15.167.4-microsoft-standard-WSL2' > "$W/wsl2"
printf '%s\n' '6.10.0-100.fc40.x86_64' > "$W/native"
printf 'MemTotal:       16000000 kB\nMemAvailable:    8000000 kB\n' > "$W/healthy"
printf 'MemTotal:       16000000 kB\nMemAvailable:     200000 kB\n' > "$W/starved"

# 1
out="$(TILLANDSIAS_GATE_MEMORY_OSRELEASE="$W/wsl2" bash "$FLOOR" 2>/dev/null)"; rc=$?
last="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | tail -n 1)"
case "$out" in
    *ok:gate-memory*) bad "arm 1: a WSL2 guest asserted ok from its own meminfo (rc=$rc): $out" ;;
    *could-not-run:gate-memory:wsl2-guest-meminfo-is-not-the-host*)
        if [ "$rc" -eq 3 ] && [ "${last#skip:}" != "$last" ]; then
            ok "arm 1: a WSL2 guest refuses to assert (rc=3, last line $last)"
        else
            bad "arm 1: named the refusal but rc=$rc / last line [$last] (want rc 3 and a skip: last line)"
        fi ;;
    *) bad "arm 1: no WSL2 refusal (rc=$rc): $out" ;;
esac

# 2
out="$(TILLANDSIAS_GATE_MEMORY_OSRELEASE="$W/wsl2" bash "$FLOOR" --meminfo-from "$W/healthy" 2>/dev/null)"; rc=$?
case "$rc:$out" in
    0:ok:gate-memory:*) ok "arm 2: a host figure passed in is judged normally (ok, rc=0)" ;;
    *) bad "arm 2: host figure via --meminfo-from not judged (rc=$rc): $out" ;;
esac

# 3
out="$(TILLANDSIAS_GATE_MEMORY_OSRELEASE="$W/wsl2" bash "$FLOOR" --meminfo-from "$W/starved" 2>/dev/null)"; rc=$?
case "$rc:$out" in
    1:refused:gate:insufficient-memory*) ok "arm 3: a starved host figure is still refused (rc=1)" ;;
    *) bad "arm 3: starved host figure not refused (rc=$rc): $out" ;;
esac

# 4
out="$(TILLANDSIAS_GATE_MEMORY_OSRELEASE="$W/native" bash "$FLOOR" 2>/dev/null)"; rc=$?
case "$out" in
    *wsl2-guest*) bad "arm 4: a native kernel was treated as a WSL2 guest (rc=$rc): $out" ;;
    *) ok "arm 4: a native kernel is not refused as WSL2 (rc=$rc, $(printf '%s' "$out" | head -n 1 | cut -c1-60))" ;;
esac

total=$((pass+fail))
if [ "$fail" -eq 0 ]; then echo "ok:gate-memory-wsl2-guest:$pass/$total"; exit 0; fi
echo "violation:gate-memory-wsl2-guest:$pass/$total"; exit 1

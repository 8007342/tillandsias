#!/usr/bin/env bash
# @trace order:329, spec:forge-hot-cold-split
# bash-dialect: dual (probed fallback) — the clock probes GNU date's %N and
# falls back to timing a REPEAT LOOP at 1-second resolution; both paths report
# correct per-op milliseconds. Marker consumed by scripts/check-bash-dialect.sh
# (761-g36m). A naive fallback is NOT acceptable here: at 1 s resolution a
# single 80 ms operation reads as 0, so the fallback amortises instead.
#
# bench-hot-path-placement.sh — one row of order 329's placement table.
#
# Answers: does a forge hot path need real tmpfs, or is disk enough? The pull
# cache is the first row: container layer blobs (large sequential) written on a
# MISS and read on a HIT. Portable on purpose — order 329 criterion 3 needs the
# same comparison on macOS (virtiofs vs Linux tmpfs), which a GNU-only timer
# could never serve.
#
# Usage: scripts/bench-hot-path-placement.sh [disk-dir] [tmpfs-dir] [blob-mb]
set -uo pipefail

# NOT ${TMPDIR:-/tmp}: on Fedora Silverblue /tmp IS tmpfs, so that default
# compares tmpfs against tmpfs and reports a confident "no difference".
# Measured 2026-08-24: with the /tmp default this script returned disk 173 ms
# vs tmpfs 174 ms; against a real NVMe path the same run is 483 vs 178.
DISK_DIR="${1:-${HOME}/.cache/tillandsias/placement-bench-disk}"
SHM_DIR="${2:-/dev/shm/placement-bench}"
BLOB_MB="${3:-512}"
[ -d /dev/shm ] || SHM_DIR="${2:-${TMPDIR:-/tmp}/placement-bench-shm}"

if printf '%s' "$(date +%N 2>/dev/null)" | grep -Eq '^[0-9]{9}$'; then  # gnu-date: ok (this IS the digit validation; BSD emits a literal N and fails the match)
    HAVE_NS=1
else
    HAVE_NS=0
    echo "# note: no GNU date %N — timing by repeat loop at 1 s resolution" >&2
fi

# run_timed <min_seconds> <cmd...>  -> per-operation milliseconds
run_timed() {
    local min_s="$1"; shift
    if [ "$HAVE_NS" -eq 1 ]; then
        local t0 t1
        t0=$(date +%s%N); "$@" ; t1=$(date +%s%N)  # gnu-date: ok (digit-validated by the HAVE_NS probe above; the fallback arm below needs no %N)
        echo $(( (t1 - t0) / 1000000 ))
        return
    fi
    # Amortise: repeat until at least min_s elapsed, then divide.
    local start now reps=0
    start=$(date +%s)
    while :; do
        "$@"; reps=$((reps + 1))
        now=$(date +%s)
        [ $(( now - start )) -ge "$min_s" ] && break
    done
    echo $(( (now - start) * 1000 / reps ))
}

blob_write() { dd if=/dev/zero of="$1/blob" bs=1M count="$BLOB_MB" conv=fsync status=none 2>/dev/null; }
blob_read()  { dd if="$1/blob" of=/dev/null bs=1M status=none 2>/dev/null; }

# A COMPARISON WHOSE TWO ARMS SHARE A FILESYSTEM IS NOT A COMPARISON. Refuse
# rather than emit "no difference" — that reading is indistinguishable from the
# real finding this script exists to produce.
mkdir -p "$DISK_DIR" "$SHM_DIR" 2>/dev/null
_dev_of() { df -P "$1" 2>/dev/null | awk 'NR==2{print $1}'; }
_d_dev="$(_dev_of "$DISK_DIR")"; _s_dev="$(_dev_of "$SHM_DIR")"
if [ -z "$_d_dev" ] || [ -z "$_s_dev" ]; then
    echo "refused:placement:undeterminable-filesystem — cannot resolve the device behind $DISK_DIR or $SHM_DIR" >&2
    exit 2
fi
if [ "$_d_dev" = "$_s_dev" ]; then
    echo "refused:placement:same-filesystem — '$DISK_DIR' and '$SHM_DIR' are both on $_d_dev." >&2
    echo "  Both arms would measure the same store and the run would report a confident 'no difference'." >&2
    echo "  Pass a disk-backed path explicitly: $0 <disk-dir> <tmpfs-dir> [blob-mb]" >&2
    exit 2
fi
echo "# disk arm: $DISK_DIR ($_d_dev)   tmpfs arm: $SHM_DIR ($_s_dev)"
printf '%-6s %-5s %11s %11s\n' STORE REP BLOB_WR_MS BLOB_RD_MS
for rep in 1 2 3; do
    for store in disk tmpfs; do
        [ "$store" = disk ] && D="$DISK_DIR" || D="$SHM_DIR"
        rm -rf "$D"; mkdir -p "$D" || { echo "cannot use $D" >&2; continue; }
        w=$(run_timed 5 blob_write "$D")
        blob_write "$D"                     # ensure the blob exists for the read
        r=$(run_timed 5 blob_read "$D")
        printf '%-6s %-5s %11s %11s\n' "$store" "$rep" "$w" "$r"
        rm -rf "$D"
    done
done
echo
echo "# RAM cost of choosing tmpfs, measured not assumed:"
free -m 2>/dev/null | awk '/^Mem:/{printf "#   total=%sMB available=%sMB — a %sMB blob is %.1f%% of available\n", $2, $7, '"$BLOB_MB"', '"$BLOB_MB"'*100/$7}' \
  || echo "#   (free(1) unavailable on this platform)"
echo PLACEMENT-BENCH-COMPLETE

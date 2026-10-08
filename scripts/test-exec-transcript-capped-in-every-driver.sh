#!/usr/bin/env bash
# @trace order:795-vq6b, spec:host-guest-transport
#
# test-exec-transcript-capped-in-every-driver.sh — every place an exec driver in
# crates/tillandsias-vm-layer/src/vsock_exec.rs ACCUMULATES guest output into a
# transcript passes it through the one cap policy (trim_transcript, directly or
# via retain_tail) within the next few lines.
#
# WHY A SOURCE SCAN: 690-eug2 capped one driver and its closure said "the exec
# transcript is capped"; a sibling driver kept an unbounded Vec<u8>. The drivers
# stay separate (collect / stream-to-callback / expect script are different
# contracts), so the next divergence has to be made loud mechanically.
#   1 at least 2 accumulators are found (vacuity floor: the scan still sees the drivers)
#   2 each accumulator is followed within 12 lines by retain_tail( or trim_transcript(
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="${TILLANDSIAS_TEST_FILE:-$ROOT/crates/tillandsias-vm-layer/src/vsock_exec.rs}"
end="$(/usr/bin/grep -n '^#\[cfg(test)\]' "$F" | head -n 1 | cut -d: -f1)"
[ -n "$end" ] || end="$(wc -l < "$F")"
out="$(awk -v E="$end" '
    NR >= E { exit }
    { line[NR] = $0 }
    /stdout\.extend_from_slice\(/ { acc[++n] = NR }
    END {
        for (i = 1; i <= n; i++) {
            a = acc[i]; ok = 0
            for (j = a; j <= a + 12 && j < E; j++)
                if (line[j] ~ /retain_tail\(|trim_transcript\(/) ok = 1
            printf "%d %s\n", a, (ok ? "capped" : "UNCAPPED")
        }
    }' "$F")"
count="$(printf '%s\n' "$out" | /usr/bin/grep -cE ' (capped|UNCAPPED)$')"
bad="$(printf '%s\n' "$out" | /usr/bin/grep 'UNCAPPED' | cut -d' ' -f1 | tr '\n' ' ')"
fail=0
[ "$count" -ge 2 ] && echo "ok:   1: $count transcript accumulators found" \
    || { echo "FAIL: 1: found $count accumulators (want >= 2); the scan no longer sees the drivers" >&2; fail=1; }
[ -z "$bad" ] && echo "ok:   2: every accumulator passes through the cap policy" \
    || { echo "FAIL: 2: uncapped transcript accumulator(s) at vsock_exec.rs line(s): $bad" >&2; fail=1; }
[ "$fail" -eq 0 ] || exit 1
echo "PASS: exec-transcript-capped-in-every-driver"

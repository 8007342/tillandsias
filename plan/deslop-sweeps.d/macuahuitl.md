# De-slop sweep ledger — macuahuitl.md (see scripts/check-deslop-due.sh)
# One record per completed sweep, appended by: check-deslop-due.sh record
# Grammar: DESLOP-SWEEP: order=<n> examined=<n> confirmed=<n> [findings=<n>] [retracted=<n>] [filed=<n>] [net_lines=<±n>]
# Read by: check-deslop-due.sh check — highest order= is the delta anchor, latest heading is the 48h floor.
#
# SEEDED, NOT SELF-REPORTED. The first record below predates the clock: the sweep
# ran on 2026-08-19, check-deslop-due.sh landed 2026-08-21. It is re-derivable,
# not typed from memory:
#   ts      = commit 345bb8ed author date in UTC
#             (git show -s --date=format-local:'%Y-%m-%dT%H:%M:%SZ' 345bb8eda, TZ=UTC)
#   order   = 834, the prefix `next-order` would have minted at that commit —
#             highest order in plan/index.yaml + plan/index.d there was 833, and
#             next-order is (highest + 1), verified against today's tree (843 -> 844)
#   examined/confirmed = 410 rows examined, 51 retracted (12.4%), from the sizing
#             note filed at 2026-08-20T01:10:00Z under packet
#             periodic-deslopification-sweep
# Written with `record --order 834 --host macuahuitl`, so the line has the same
# provenance as every line after it.
#
# ONE DISCREPANCY LEFT UNRESOLVED, recorded rather than smoothed over: the sweep
# commit's subject says "41 rows closed" while the sizing note says 51 of 410.
# The operator ruling that sized this clock cites 51/410, so 51 is what is
# recorded. Nothing in the trigger rule depends on which is right — the clock
# reads `order=`, never `confirmed=` — but the kill rule does, so a later sweep
# should reconcile the two before counting this record.
#
# WITHOUT THIS SEED the clock would read `reason=no-record` and fire a sweep
# immediately, over a queue that grew ten orders since the last one. That is the
# low-yield burn the whole event-counted design exists to avoid.

## 2026-08-20T00:54:44Z macuahuitl
DESLOP-SWEEP: order=834 examined=410 confirmed=51 retracted=51

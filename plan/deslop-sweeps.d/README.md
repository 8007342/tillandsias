# De-slop sweep ledger

Durable, committed record of every de-slop sweep the fleet has run (packet
`periodic-deslopification-sweep`, order 829-dkuc). One file per host —
`<host>.md` — so concurrent hosts append without cross-host merge conflicts,
the same fragment philosophy as `plan/mo-full-attestations.d` (651-2x5s) and
`plan/loop_status.d` (582-nqw5).

- **Writer**: `scripts/check-deslop-due.sh record --examined <n> --confirmed <n>`
  — refused without both numbers, because the sweep's kill rule counts only
  sweeps that examined new rows.
- **Reader**: `scripts/check-deslop-due.sh check` — the trigger clock. Due when
  `(current_order - order_at_last_sweep) >= 200`, with a 48h floor and **no**
  calendar ceiling. The full reasoning lives in that script's header; the short
  version is that a ceiling would fire low-yield sweeps on a quiet fortnight and
  `red:two-sweeps-zero-confirmed` would then retire the reconciler for doing
  nothing wrong.
- **Not a build gate.** Nothing in `./build.sh` consults this. It is a scheduler
  input the meta-orchestration cycle reads.
- **Host label**: the shared `tillandsias_node_name()` probe in
  `scripts/agent-identity.sh` — the same one that names the MO-FULL ledger
  files, so the two directories cannot disagree about what this host is called.

Entry shape (the reader takes the highest `order=` across **all** files as the
delta anchor, and the latest heading timestamp as the 48h floor — the clock is
fleet-wide even though the files are per-host):

    ## <ISO-UTC-timestamp> <host>
    DESLOP-SWEEP: order=<n> examined=<n> confirmed=<n> [findings=<n>] [retracted=<n>] [filed=<n>] [net_lines=<±n>]

Fields are space-split and anchored, so records may grow new fields in any
order without breaking the reader. A record whose heading is missing or whose
`order=` is absent is a **refusal** (`fail:deslop-due:unparseable-record:…`),
never "no record" — read as empty it would fire a sweep off a lie, read as
current it would suppress one.

Why this is committed rather than a host-local dotfile: the sweep operates on
the shared plan ledger, so "when did the last sweep run" has exactly one true
answer for the whole fleet. A cache-dir marker would give every host a private
clock and the fleet would sweep the same rows repeatedly.

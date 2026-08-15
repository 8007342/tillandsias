## Cycle 2026-08-14 tlatoani (linux_immutable) — MCP outages stop being invisible

Direction: forge-local EXPERTS. Batch: `forge-local-experts-milestone`
(seed `host-20260814`, size 10, budget 10, pick 2/3). Triage: eligible=145
grouped=126 ungrouped=19 epics=10.

**Drained 737-zcj5** `mcp-expert-outages-are-invisible-to-the-plan` -> implemented.
The packet asked for a MECHANISM, not a mea culpa, and this cycle supplied one
after reproducing the defect on itself: this session began on `main`, which
carries no `.mcp.json`, so it never loaded the experts and did every read through
`./target/release/tillandsias-plan` — the exact unrecorded fallback windows filed
the packet for, on a second host, the same day.

- NEW `scripts/check-mcp-expert-health.sh` — speaks the MCP `initialize`
  handshake to each expected expert, prints one line matching
  `^(ok:experts-healthy|down:<csv>|absent:not-registered|skip:<reason>)$`, and
  appends one JSONL record per server UNCONDITIONALLY. The trace no longer
  depends on an agent choosing to write it. ~38ms healthy.
- `scripts/cycle-metrics.sh` `mcp:` line gains `health=`, sourced from that log
  rather than from usage. This is the criterion-2 fix: call volume cannot see an
  outage, because a down server and an uncalled server both produce zero rows.
  `health=unprobed` is deliberately NOT `health=ok`.
- NEW `mcp_outage:` line, emitted ONLY on a recorded non-up state. A healthy
  cycle stays silent (criterion 3). Verified both ways.
- `methodology/distributed-work.yaml` gains `filesystem_fallback.unavailable_record_where`
  naming probe -> log -> metrics -> loop-status. The rule said "record it" and
  named no destination, which is part of why two hosts skipped it (criterion 4).
- Pinned by NEW `litmus:mcp-expert-health-probe-shape`, 11/11 PASS.

**A false outage is as bad as a missed one.** The probe's first draft read
`.command` and dropped `.args`; the repo's own `.mcp.json` registers
`command: "bash"` with the script in `args`, so it launched a bare `bash` and
reported both HEALTHY experts as down. Caught by handshaking the real server.
The fixture pins it: reintroducing the bug flips 3 of 6 scenarios to FAIL.

**Filed 740-88hz** `e2e-eligibility-grammar-step-inherits-podman-latency` (p2).
The meta-orchestration pre-build instant suite returned PASS:11 FAIL:1, and the
failure was NOT this cycle's: `litmus:e2e-eligibility-probe-shape` STEP 4
TIMEOUT at 5s. Measured immediately after on the same tree: the probe answers
`eligible` in 0.118s, and 10 consecutive runs stayed 0.10-0.12s. STEP 4 is the
only step in that litmus reaching live podman — STEPS 2 and 3 both neutralise it
with a fake `XDG_RUNTIME_DIR` — so a GRAMMAR assertion is paying for an unbounded
`podman ps`/`podman info`. Filed with the measurement so the next host does not
re-derive it, or re-run until green and call it noise.

**Not filed, already open:** the Start-Of-Day gate keys on a
`.last-daily-maintenance` marker that nothing in the repo writes. That is
719-546b-3 (`start-of-day-maintenance-and-post-restart-verification-automation`,
ready, v0.5, p2, linux), whose deliverable is exactly that script. Checked before
filing rather than after.

Metrics: `experts: calls=32 answered=32 answer_rate=100%` ·
`mcp: health=ok` (no `mcp_outage:` line — the negative control, in the real
handoff path) · `expert_accuracy: pass=20 total=20 rate=100%` ·
`flow: source=absent` before this cycle, first record emitted now ·
stranded `in_progress=1 stranded=0` · ledger `compaction: eligible=true
fragments=27 malformed=0` (left to a coordinator cycle; uncompacted is slower,
never wrong).

Gate: `./build.sh --check` PASS in the `tillandsias-builder` toolbox, gate stamp
recorded. Release: untouched by design — this host does not own releases.

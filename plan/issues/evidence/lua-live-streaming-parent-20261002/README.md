# Independent parent runtime verification

@trace order:1534-puyz

## Verified landing

PR #207 is merged, and remote `linux-next` at
`7b829b20583130067432069ecf0bc0586af4ce86` contains the reviewed advisory
repair and behavior-preserving strict supervisor lint repair. The serialized
forced integration gate exited 0 in 1038.469 s. `landing-status.json`,
`landing.log` and `merge-confirmation.json` retain that result and subsequent
merge confirmation. The driver observed GitHub's asynchronous merge state
as OPEN immediately after its push; the later confirmation proves MERGED.
The bounded 1534 packet is closed, not the larger 1384 runtime parent.

## Targeted independent controls

The parent reran the final candidate's Lua/policy targets with default
parallelism: 83/83, executor targets 28/28, script-run unit tests 3/3 and
script-run shell checks 7/7. These 114 Rust tests and seven shell checks are
targeted results, distinct from the full gate and not a native macOS/Windows
attestation.

`advisory-before.json` and `advisory-after.json` use the same Lua source:
a caught valid advisory followed by a process launch. The original candidate
creates the marker; the repaired candidate does not. Advisory stdout and
exit 0 stay unchanged. `advisory-probe.lua.source.txt` retains source data.

`deadline-after.json` reuses the exact original acknowledged producer and
probe fixture bytes, with a copied final debug binary and isolated scratch
index. Startup ACK is 42.174 ms; the 700 ms outer deadline returns exit 124
at 705.949 ms. The direct child is gone and descendant is a non-running
zombie at runner exit, then the diagnostic subreaper reaps it. Neither writes
delayed markers; no harness kill was needed. The positive control writes both
markers and exits 0. This does not claim runner waitpid of a grandchild.

`recheck-script-deadline.sh.source.txt` is non-executable archival diagnostic
source data. Reproduction materializes it only in external scratch. Its first
attempt was invalid because the copied scratch lacked `plan/index.yaml`;
no child started. The corrected attempt copies the original scratch index
and creates a `.git` stub before execution. Do not count the setup failure as
a runtime failure or as cleanup evidence.

`cli-live-ack.json` independently verifies the command-line binary with an
external bounded shell producer. That producer cannot finish successfully
until the live stdout callback creates ACK, so capture replay cannot make
this probe green. The Lua source separately asserts CR-preserving stdout,
stderr callbacks and full captured result bytes. It passes with exact
`ok:parent-cli-live-ack:2:1` output and no stderr. Sources are archived as
non-executable `cli-live-producer.sh.source.txt` and
`cli-live-probe.lua.source.txt`.

An extra attempt to invoke the older packet's `scripts/test-plan-run-verb.sh`
did not run: that path is absent in this checkout. It is not counted as a
passing test or evidence for closing 1375-amye; that packet remains open.

## Remaining boundaries

The gate's reported litmus closures were not exercised by `--check`.
Composition, per-process trace, deliberate process-group escape containment
and changed native-platform evidence remain separate open obligations.
The active ledger schedule is in
`plan/issues/remaining-composition-and-trace-handoff-2026-10-02.md`.

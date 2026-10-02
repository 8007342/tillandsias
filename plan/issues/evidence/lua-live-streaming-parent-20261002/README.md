# Independent parent runtime verification

@trace order:1534-puyz

The parent reran the final candidate's Lua/policy targets with default
parallelism: 83/83, executor targets 28/28, script-run unit tests 3/3 and
script-run shell checks 7/7. These are targeted results, not a full gate or
native macOS/Windows attestation.

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

Full forced parent integration and confirmed remote ancestry remain required
before this packet closes. Composition, per-process trace and changed native
platform evidence remain separate open obligations.

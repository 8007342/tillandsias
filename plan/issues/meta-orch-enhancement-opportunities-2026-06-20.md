
## 2026-07-10: trace-generator churn makes exit contracts slower (enhancement)

generate-traces.sh (run via build/commit hooks) rewrites a DIFFERENT
subset of TRACES.md files on successive runs (mtime/ordering cascades),
so every overnight cycle chases straggler diffs at exit-contract time —
five separate straggler commits tonight. Candidate: make the generator
deterministic (stable ordering, content-hash short-circuit) or move
TRACES refresh into an explicit cadence instead of ambient hooks.

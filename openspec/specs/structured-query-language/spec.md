<!-- @tombstone superseded:runtime-logging+log-aggregation -->
<!-- @trace spec:structured-query-language -->
# structured-query-language Specification (Tombstone)

## Status

obsolete

## Deprecation Notice

This spec and its only implementation, the Loki-style log query language in
`crates/tillandsias-logging/src/query.rs` (parser, executor, 16 unit tests)
and the `scripts/query-traces.sh` CLI that re-implemented the same grammar in
jq, were retired together under packet 781-hseq
(`log-query-language-has-zero-consumers`) on 2026-10-12.

There is no backwards-compatibility commitment. No surface ever called the
module: it was traced, tested and re-exported, and nothing outside its crate
imported it in the five months since it landed (wave 21, 2026-05-14). The
script that was meant to be its CLI never reached the Rust path — its
`execute_query_rust` wrote a stub and fell through to jq — and nothing called
the script either.

## Historical Context

The requirement read "Trace query tooling MUST support structured predicates
over trace metadata instead of relying only on ad hoc text search". No trace
query tooling exists that this spec governed, and the owning telemetry
milestone (682-u3si, local-telemetry-for-bottleneck-finding) asks for
append-log telemetry and a committed bucketed distillation, not a query
language. Structured JSON reads in scripts go through `tillandsias-plan json`
(1375-rn9b), which the jq call-site ratchet enforces.

## Replacement References

- `openspec/specs/runtime-logging/spec.md` — the logging layer that stays
- `openspec/specs/log-aggregation/spec.md` — multi-container log merging

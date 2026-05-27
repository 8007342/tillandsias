# plan/diagnostics/ — Forge Completeness Trail

This directory holds the durable record of forge container capability
measurements. It is the convergence trail for the forge-diagnostics
automation wave.

## File Lifecycle

| Role | File | Committed? |
|---|---|---|
| Evolving diagnostic prompt | `forge-diagnostics-prompt.txt` | YES |
| Completeness baseline | `forge-completeness-baseline-*.md` | YES |
| Per-run summary | `diagnostics_<timestamp>-summary.md` | YES |
| Raw diagnostics log | `target/forge-diagnostics/diagnostics_*.log` | NO |

## Prompt Evolution Rule

Items in the diagnostic prompt are removed once they are covered by a
proper spec + litmus test (not just static grep). Items are added when
a capability gap is discovered during E2E testing.

The goal is for the prompt to shrink over time as forge completeness
increases and is validated by dedicated spec/litmus pairs.

## Consumption by Agents

1. An E2E litmus test or standalone orchestration runs:
   `tillandsias . --opencode --diagnostics --prompt "$(cat forge-diagnostics-prompt.txt)"`
2. Raw output lands in `target/forge-diagnostics/diagnostics_<ts>.log`
3. `scripts/distill-forge-diagnostics.sh` reads the log and writes a dated
   summary to this directory
4. Agents read the latest summary, compare to previous, and decide:
   - Which capabilities are now verified → remove from prompt
   - Which gaps need spec/litmus work → create plan issue
   - Which regressions appeared → investigate

## Methodology Gap

Resolved by `methodology/litmus.yaml` and `methodology/forge-diagnostics.yaml`.
`agent_diagnostic` is a non-blocking annex signal: parent E2E tests may pass
while diagnostics record missing forge capabilities. Proposed forge
enhancements still require orchestrator approval for privacy/isolation before
they become implementation work.

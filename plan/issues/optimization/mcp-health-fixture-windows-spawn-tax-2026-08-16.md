# MCP health fixture pays a ~98s process-spawn tax on windows

- date: 2026-08-16
- host: windows (Yolanda, Git Bash / MSYS)
- class: optimization
- discovered_by: windows meta-orchestration cycle 4 while landing 770-f6u4
- artifact: `scripts/check-mcp-expert-health.sh fixture` +
  `openspec/litmus-tests/litmus-mcp-expert-health-probe-shape.yaml` step 2

## Observation

The 770-f6u4 tool-call-depth upgrade grew the hermetic fixture to 20
scenarios. Each scenario re-invokes the probe (`bash "$_fx_self"`), and each
probe costs roughly 15 process spawns (jq registration reads, the stand-in
server, `timeout`, `env`, two scan jq passes). Linux prices that in
single-digit seconds; MSYS prices a spawn at ~100x, so the full fixture
measured **98s wall / 79s sys** on this host (2026-08-16). The litmus step
budget was raised from 30s to 180s to stay honest about the slowest host.

The per-line jq scan (one jq spawn per stdout line — ~240 spawns for the
chatty scenario alone) was already replaced with a single `jq -R fromjson?`
pass per scan during the same change; the residual cost is the per-scenario
re-invocation, not the scanning.

## Why it matters

`litmus:mcp-expert-health-probe-shape` is `size: instant` and pre-build, so
the 98s lands in every windows gate run — a fixed per-cycle cost, exactly the
class the experts-reliability story exists to reduce. It does NOT block: the
step passes well inside 180s.

## Candidate reductions (pick one, keep coverage)

1. Batch scenario execution: source the probe once and call `main` as a
   function per scenario instead of re-invoking bash (saves ~20 bash
   startups + re-parsing).
2. Collapse the four per-server jq registration reads
   (registered/command/argv0/env) into one jq emitting all four fields.
3. Run the DOWN-expecting scenarios against a single combined registration
   where each server name maps to a distinct stand-in, cutting invocations
   ~in half without losing any verdict assertion.

## Repro

```bash
time bash scripts/check-mcp-expert-health.sh fixture   # ~98s on windows, MSYS
```

---
title: Optimize forge diagnostics prompt — remove permanently passing checks
gap: "forge diagnostics runner reports 'All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.' on every 25/25 pass"
category: tooling
status: proposed
proposed_at: 2026-06-20T17:55:00Z
proposed_by: linux-forge-continuous-enhancement
---

## Gap

The forge diagnostics prompt at `plan/diagnostics/forge-diagnostics-prompt.txt` includes ~20 checks, many of which (agent availability, entrypoint paths, network isolation, cache routing, shell helpers) have passed 25/25 on every recent run. The diagnostics runner now outputs:

> "All forge capabilities nominal. Consider removing checked items from the diagnostics prompt."

## Recommended Approach

1. Review which checks in `plan/diagnostics/forge-diagnostics-prompt.txt` have returned the same passing value for N consecutive runs (e.g., `opencode`, `claude`, `codex` always found; `external_curl` always `000`/`BLOCKED`; `CACHE_HOME` paths always set).
2. Remove or demote permanently-green checks to reduce noise and focus diagnostics on regressions.
3. Keep meaningful checks that detect regressions (e.g., `inference_reachable` varies with podman state, `tillandsias_help` could break after an image change).
4. Run diagnostics for N cycles and confirm output is shorter but still catches real regressions.

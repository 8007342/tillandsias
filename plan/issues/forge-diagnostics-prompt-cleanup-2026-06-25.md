# Forge Diagnostics Prompt — Clean Up Permanently-Green Checks

**Source:** Proposal at `plan/forge-improvements/proposals/2026-06-20-diagnostics-prompt-optimize.md`
**Status:** proposed
**Owner host:** linux
**Discovered:** 2026-06-20T17:55:00Z (proposal filed); reconfirmed 2026-06-25

## Summary

The forge diagnostics prompt (`plan/diagnostics/forge-diagnostics-prompt.txt`) runs 25+ checks every diagnostics cycle. Many of these checks have returned the same passing value on every run since the diagnostics system was established:

- `opencode`, `claude`, `codex` — always found (agent binaries baked into image)
- `bash_entrypoint`, `opencode_entrypoint` — always present (immutable image paths)
- `external_curl` — always `000`/`BLOCKED` (network isolation holds)
- `CARGO_HOME`, `npm_config_cache`, `GOPATH`, `GRADLE_USER_HOME` — always set (environment vars in entrypoint)
- `tmpfs_mounts`, `cheatsheets_df`, `src_df`, `tmp_df` — stable (image mounts unchanged)
- `welcome_paths` — always populated (baked into image)
- `user_id`, `cwd` — always resolve (container entrypoint)

The diagnostics runner itself now outputs on every run:

> "All forge capabilities nominal. Consider removing checked items from the diagnostics prompt."

## Impact

- **Noise**: Every diagnostics run returns the same 25/25 pass with zero actionable diagnostics. The `diagnostics` array is always `[]`.
- **Wasted tokens**: The LLM agent inside the forge parses and outputs 141 lines of prompt text + JSON for what could be a focused 8-10 check regression detector.
- **Missed regressions**: With so many static passes, a real regression in a dynamic check (e.g., `inference_reachable`, `tillandsias_help`) is visually drowned out.

## Recommended Action

1. Review `plan/diagnostics/forge-diagnostics-prompt.txt` and identify checks that have returned the same passing value for 5+ consecutive runs.
2. Remove or demote permanently-green checks to a `[baked-in]` marker comment.
3. Add a version-stability check: instead of testing individual paths, test that the forge image version hasn't regressed (`cat /VERSION`).
4. Keep genuinely dynamic checks: `inference_reachable`, `tillandsias_help`, `external_curl`, `proxy_url`, `OPENCODE_INIT_PROMPT_FILE`.
5. Run diagnostics for 3 cycles and confirm output is shorter but still catches regressions.

## Files

- `plan/diagnostics/forge-diagnostics-prompt.txt` — the prompt file to edit
- `plan/diagnostics/diagnostics_20260623T090550Z-summary.md` — latest run showing 25/25, all static
- `plan/forge-improvements/proposals/2026-06-20-diagnostics-prompt-optimize.md` — original proposal

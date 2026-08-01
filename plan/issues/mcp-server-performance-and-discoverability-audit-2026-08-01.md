# MCP Expert Servers Performance & Discoverability Audit

- **Date**: 2026-08-01
- **Audited By**: Google Antigravity (`forge-google-antigravity-gemini3.6flash-20260801`)
- **Target Servers**:
  - `project-plan` / `forge-plan`: `images/default/config-overlay/mcp/forge-plan.sh`
  - `project-info`: `images/default/config-overlay/mcp/project-info.sh`
- **Context**: Validation of local MCP server performance, usage, and discoverability to unblock future forge launches and accelerate agent task execution.

---

## 1. Measured Performance & Latencies

| MCP Server | Tool Invoked | Subsystem / Operation | Measured Latency | Output Characteristics |
|---|---|---|---|---|
| `project-plan` (`forge-plan.sh`) | `plan_ready` | Role-filtered plan packet query | **52.68 ms** | 122 ready items formatted |
| `project-plan` (`forge-plan.sh`) | `plan_status` | Status lookup by packet reference | **52.23 ms** | Single packet status line |
| `project-plan` (`forge-plan.sh`) | `plan_check` | Plan ledger schema & integrity check | **49.97 ms** | 40 lines of warnings/validation |
| `project-plan` (`forge-plan.sh`) | `plan_burndown` | Milestone burndown tracking | **51.88 ms** | 75 status lines for milestone children |
| `project-plan` (`forge-plan.sh`) | `plan_answer` | Cited plan envelope query | **57.47 ms** | Exact cited envelope with source_commit |
| `project-plan` (`forge-plan.sh`) | `methodology_ask` | Methodology discipline routing | **53.12 ms** | Exact cited envelope (distributed-work rule) |
| `project-info` (`project-info.sh`) | `plan_query` | Status/role/tag matching | **86.76 ms** | JSON array of 370 matching items |
| `project-info` (`project-info.sh`) | `git_status` | Working tree status check | **23.99 ms** | Structured JSON git status |
| `project-info` (`project-info.sh`) | `read_file` | Offset/limit text view | **21.48 ms** | Fast sliced file lines |
| `project-info` (`project-info.sh`) | `search_code` | Code pattern search | **66.94 ms** | Structured search output |

**Key Finding**: Both local MCP servers execute with extreme speed (**21 ms to 86 ms**), providing sub-100ms structured and cited responses. They completely replace expensive full-file reads or heavy regex context-crawling for plan selection and navigation.

---

## 2. Identified Shortcomings & Actionable Fixes for Future Forge Launches

### Shortcoming 1: Ephemeral Container Prebuilt Binary Skew (`tillandsias-plan`)
- **Symptom**: When a forge container launches from a `main` snapshot, `$HOME/.local/bin/tillandsias-plan` binary baked into the image during initial provision may pre-date subcommands added to `crates/tillandsias-plan` (`answer`, `methodology-ask`, `verify-answer`).
- **Observed Behavior**: `forge-plan.sh` fail-soft guard correctly returns `confidence: unsupported` typed envelopes without crashing or hallucinating, but answer capabilities remain unavailable until `tillandsias-plan` is recompiled.
- **Actionable Fix**: `ensure_forge_experts` in `lib-common.sh` must ensure `tillandsias-plan` is built from the active checkout branch (`linux-next`), and `forge-policy-binary-discoverability` (order 561) / `forge-experts-capability-honesty` (order 569) must resolve `tillandsias-plan` from `$CARGO_TARGET_DIR` when redirected.

### Shortcoming 2: Harness MCP Server Discovery Registration Gaps
- **Symptom**: While OpenCode receives `git-tools`, `project-info`, `host-browser`, and `forge-plan` via `config-overlay/opencode/config.json` + `apply_opencode_config_overlay()`, non-OpenCode harnesses (e.g. Claude Code or generic forge runners) have no automatic registration pointer injected at launch.
- **Actionable Fix**: Implement order 568 (`claude-mcp-config-registration`) to merge `mcpServers` into `~/.claude.json` at entrypoint (`entrypoint-forge-claude.sh`), or commit a repo-root `.mcp.json` with degrade-gracefully wrapper scripts.

### Shortcoming 3: Missing `TILLANDSIAS_AGENT` Environment Export
- **Symptom**: `tillandsias-headless` tray launcher builds container launch specs without exporting `TILLANDSIAS_AGENT` (e.g. `claude`, `opencode`, `opencode-web`), preventing harness-affinity selection from identifying the active agent harness.
- **Actionable Fix**: Implement order 570 (`forge-launch-sets-tillandsias-agent`) to export `TILLANDSIAS_AGENT` in container profile env specs.

---

## 3. Plan Ledger Tracking

- Order **554** (`harness-mcp-expert-validation`): Milestone for harness expert validation.
- Order **557** (`claude-mcp-expert-validation`): Updated with empirical performance timings and prebuilt binary resolution findings.
- Order **561** (`forge-policy-binary-discoverability`): Completed (binary resolution for `tillandsias-policy` and `tillandsias-podman-cli` under `CARGO_TARGET_DIR`).
- Order **568** (`claude-mcp-config-registration`): Ready for implementation.
- Order **569** (`forge-experts-capability-honesty`): Ready for implementation.
- Order **570** (`forge-launch-sets-tillandsias-agent`): Ready for implementation.

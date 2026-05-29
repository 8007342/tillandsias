# Forge Diagnostics Summary — 2026-05-28T12:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T111351Z.log`
- **Forge version**: 0.2.260527.5
- **Completeness**: 20 / 25 checks passed (80%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 80%

## Missing Capabilities

- `hot_paths.cheatsheets`
- `environment.TILLANDSIAS_CHEATSHEETS`
- `agent_instructions.paths`
- `agent_instructions.discipline_content_first_lines`
- `shell.tillandsias_help`

## Recommended Actions

- Verify tmpfs mount sizes in build_podman_args() for cheatsheets
- Investigate missing capability: environment.TILLANDSIAS_CHEATSHEETS
- Check that cache-discipline.md is properly mounted into ~/.config/opencode/instructions/
- Investigate missing capability: agent_instructions.discipline_content_first_lines
- Ensure tillandsias-help shell function is sourced (check shell-helpers.sh)

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rustc
- cargo
- rust-analyzer
- clippy
- rustfmt
- cargo-nextest
- cargo-chef
- cargo-audit
- cargo-watch
- go
- delve
- pyright
- ruff
- wasm-pack
- trunk
- typos
- just
- watchexec
### Proposed enhancements
- rust: rust-toolchain — CARGO_HOME is pre-configured to /home/forge/.cache/tillandsias-project/cargo but rustc, cargo, and the entire Rust toolchain are absent. Pre-install rustc, cargo, rust-analyzer, clippy, rustfmt, cargo-nextest, cargo-chef, cargo-audit, cargo-watch for a productive Rust forge.
- go: go-toolchain — GOPATH is pre-configured to /home/forge/.cache/tillandsias-project/go but the Go compiler and delve debugger are absent.
- python: pyright+ruff — Python3 is installed but no LSP (pyright) or linter/formatter (ruff) are present. Both are essential for IDE-quality development in the forge.
- wasm: wasm-pack+trunk — Project genus is 'tillandsias' which uses WASM/Rust. wasm-pack (build) and trunk (bundler/dev-server) enable the WASM development workflow end-to-end.
- other: typos — Source-code spell checker used in CI pipelines and pre-commit hooks. Absent despite being a common dependency in Rust/Python project quality gates.
- other: just — Modern command runner alternative to Make. Increasingly used in Rust/Python projects for build/test workflows.
- other: watchexec — File-change watcher used by cargo-watch and general dev-loop automation. Absent despite being a foundational dev tool.
- other: forge-docs — /opt/cheatsheets does not exist and TILLANDSIAS_CHEATSHEETS is unset. The welcome banner references help.sh but no discoverable reference material is available. Create /opt/cheatsheets with forge reference docs, and populate ~/.config/opencode/instructions/ with cache-discipline.md and agent instructions.
- other: tillandsias-help — Shell helper registered in welcome scripts but not installed in PATH. Install a tillandsias-help script that documents forge commands, environment variables, and workflow.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260528T111351Z.stderr.log`
- **Total launch events**: 8
- **state=running**: 3
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
```

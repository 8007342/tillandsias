# Forge Diagnostics Summary — 2026-05-28T18:42:49Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T184249Z.log`
- **Forge version**: 0.2.260528.1
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

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- Proxy gating: external curl returns 403 (not 000/timeout), meaning the proxy at http://proxy:3128 is reachable and responds; isolation depends entirely on proxy ACL correctness
- no_proxy includes subnet 10.0.42.0/24 providing a potential bypass path around the proxy
- TILLANDSIAS_OPENCODE_PROMPT env var leaks the full task specification (including isolation rules) into the environment; visible via `env` to any process

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rustc/cargo/rustup (Rust toolchain)
- rust-analyzer
- cargo-nextest
- cargo-audit
- cargo-deny
- pip3 (Python package manager)
- uv (Unix package manager for Python, though UV_CACHE_DIR is set)
- pyright
- ruff
- mypy
- pytest
- typescript-language-server
- fd-find
- make
### Proposed enhancements
- rust: Rust toolchain (rustc, cargo, rustup) — CARGO_HOME and CARGO_TARGET_DIR are preconfigured but no Rust toolchain is installed; users cannot compile Rust code or run cargo commands
- rust: rust-analyzer — Essential LSP for Rust development; missing despite Rust being the project's primary ecosystem
- rust: cargo-nextest, cargo-audit, cargo-deny — Standard Rust CI/dev tools; nextest for parallel testing, audit/deny for supply-chain security
- python: pip3 or uv — Python 3.14.5 is installed but no package manager is available; UV_CACHE_DIR is preconfigured suggesting uv was intended
- python: pyright, ruff, mypy, pytest — No Python language server, linter, type checker, or test framework; Python dev is effectively impossible
- web: typescript-language-server — Node 22/npm 10 are present but no TypeScript language server for editor integration
- other: fd-find — Commonly used file search utility; ripgrep (rg) is present but fd is not
- other: make — Many Rust and C projects require make for build; build.sh may depend on it
- other: cheatsheets content at /opt/cheatsheets — TILLANDSIAS_CHEATSHEETS is unset and /opt/cheatsheets is missing; discoverability docs are absent
- other: tillandsias-help shell helper — Command referenced in welcome bundle (help.sh) but not installed; new users have no built-in help entry point

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260528T184249Z.stderr.log`
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

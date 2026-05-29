# Forge Diagnostics Summary — 2026-05-28T12:09:46Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T120919Z.log`
- **Forge version**: 0.2.260528.1
- **Completeness**: 21 / 25 checks passed (84%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 84%

## Missing Capabilities

- `environment.TILLANDSIAS_CHEATSHEETS`
- `agent_instructions.paths`
- `agent_instructions.discipline_content_first_lines`
- `shell.tillandsias_help`

## Recommended Actions

- Investigate missing capability: environment.TILLANDSIAS_CHEATSHEETS
- Check that cache-discipline.md is properly mounted into ~/.config/opencode/instructions/
- Investigate missing capability: agent_instructions.discipline_content_first_lines
- Ensure tillandsias-help shell function is sourced (check shell-helpers.sh)

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- External internet reachable: curl to https://example.com returned 403 (not BLOCKED). Container has outbound HTTP access via proxy at http://proxy:3128, which weakens network isolation intent.
- HTTP_PROXY/HTTPS_PROXY/http_proxy env vars are set to http://proxy:3128, providing explicit egress path to external hosts.
- Inference service at http://inference:11434 is reachable (yes) — intentional but confirms internal service mesh connectivity.
- No_PROXY includes wide subnet 10.0.42.0/24 plus named hosts, potentially allowing direct (non-proxied) outbound connections to those destinations.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- cargo
- rustc
- rustup
- rust-analyzer
- pip3
- poetry
- pyright
- ruff
- go
- gopls
- delve
- gdb
- lldb
- strace
- valgrind
- yarn
- pnpm
- gradle
- kotlin
- docker
- dart
- flutter

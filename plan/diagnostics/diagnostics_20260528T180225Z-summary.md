# Forge Diagnostics Summary — 2026-05-28T18:02:42Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T180225Z.log`
- **Forge version**: 0.2.260528.1
- **Completeness**: 23 / 27 checks passed (85%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 85%

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

- External curl returned HTTP 403 from proxy (Squid) rather than being completely blocked — the proxy permits outbound TCP connections and only denies at the HTTP layer; a tool that tunnels over HTTPS to an allowed host could bypass the block. Consider a network-level egress deny as defense-in-depth.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rust-analyzer
- rustc
- cargo
- pyright
- ruff
- black
- mypy
- gopls
- golang
- delve
- typescript-language-server
- eslint
- prettier
- clangd
- gcc
- g++
- cmake
- make
- gdb
- podman
- kubectl
- yq
- deno
- bun
### Proposed enhancements
- rust: rust-analyzer, rustc, cargo — Missing Rust toolchain and LSP — Tillandsias uses Rust for forge tooling; without these, Rust code navigation, type-checking, and compilation are impossible inside the forge
- python: pyright, ruff, black, mypy — No Python language server, linter, formatter, or type checker — core Python dev experience is incomplete
- other: golang, gopls, delve — Missing Go toolchain, LSP, and debugger — Go is a common forge workload language
- web: typescript-language-server, eslint, prettier — Missing JS/TS language server and standard formatter/linter — web workloads lack IDE-grade support
- other: clangd, gcc, g++, cmake, make, gdb — Missing C/C++ toolchain, build system, LSP, and debugger — native-code workloads unbuildable
- other: podman, kubectl — Missing container and orchestration CLIs — cannot build, run, or deploy containers from within the forge
- other: yq — Missing YAML processor — YAML-heavy workflows (k8s, CI, OpenSpec) depend on yq for querying and manipulation
- other: cache-discipline.md agent instruction file — ~/.config/opencode/instructions/ does not exist; agents lack guidance on cache routing semantics, causing wasteful cache-write patterns
- other: tillandsias-help shell helper — tillandsias-help not found — developers have no built-in discoverability for forge-specific commands and conventions
- other: /opt/cheatsheets provisioned mount — Hot/cold storage split not implemented; /opt/cheatsheets is missing and TILLANDSIAS_CHEATSHEETS is unset, so cold-stored artifacts cannot be accessed

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260528T180225Z.stderr.log`
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

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 112   |

#### container_stderr — top 5 containers by line count
```
    104 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

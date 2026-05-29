# Forge Diagnostics Summary — 2026-05-28T18:00:20Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260528T180004Z.log`
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

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- rust-analyzer
- gopls
- pyright
- typescript-language-server
- delve
- rustc
- cargo
- go
- gcc
- g++
- make
- cmake
- rustfmt
- gofmt
- black
- prettier
### Proposed enhancements
- rust: rustup + rustc + cargo + rust-analyzer + rustfmt — Cache path CARGO_HOME already configured; Rust toolchain is a top-tier forge requirement for Rust projects
- go: go + gopls + gofmt + delve — Cache path GOPATH already configured; Go is widely used and absence blocks Go project development
- python: pyright + black — Python 3.14 is installed but lacks language server and formatter — both are table stakes for IDE-quality editing
- web: typescript-language-server + prettier — Node.js v22 is installed but lacks a TS language server and universal formatter
- other: gcc + g++ + make + cmake — Essential build toolchain absent; blocks native extension compilation and C/C++ projects
- other: /opt/cheatsheets directory + tillandsias-help script — TILLANDSIAS_CHEATSHEETS env var is unset and /opt/cheatsheets missing; tillandsias-help not found — discoverability is degraded
- other: cache-discipline.md agent instruction file — Agent instruction directory exists but contains no .md files; cache discipline policy is not loaded into agent context

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260528T180004Z.stderr.log`
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
| event:container_stderr     | 110   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

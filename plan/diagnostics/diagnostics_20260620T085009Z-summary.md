# Forge Diagnostics Summary — 2026-06-20T08:51:54Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T085009Z.log`
- **Forge version**: 0.3.260620.1
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 27 / 27 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- flutter
- nix
- delve
- golangci-lint
- hadolint
- typos-cli
- cargo-machete
- lua-language-server
### Proposed enhancements
- dart: Flutter SDK — Dart SDK is installed but Flutter SDK is absent; Flutter development requires the full SDK
- nix: Nix package manager — Project cheatsheets reference nix-flake-basics; nix is required for reproducible builds per methodology
- go: delve (dlv) — Go debugger — standard Go tooling absent from the forge
- go: golangci-lint — Standard Go linter for code quality in CI and local development
- other: hadolint — Dockerfile linter — essential for container-based forge development
- other: typos-cli — Source code spell checker for catching typos in CI quality gates
- rust: cargo-machete — Detects unused Rust dependencies; complements cargo-deny and cargo-audit already present
- other: lua-language-server — LSP support for Lua configuration files that may appear in the project

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T085009Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
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
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 85   |

#### container_stderr — top 5 containers by line count
```
     77 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

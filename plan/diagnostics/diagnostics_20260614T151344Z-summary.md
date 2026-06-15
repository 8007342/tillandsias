# Forge Diagnostics Summary — 2026-06-14T15:14:04Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T151344Z.log`
- **Forge version**: 0.3.260614.5
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- delve
- taplo
- yaml-language-server
- dprint
### Proposed enhancements
- go: delve — Go is installed and GOPATH is routed but delve debugger is absent; needed for investigating Go programs in the codebase
- rust: taplo — TOML language server/formatter; directly useful for Cargo.toml and Rust project config
- other: yaml-language-server — YAML LSP for workflow files, CI configs, and compose/manifest files
- other: dprint — Multilingual extensible formatter; complements cargo fmt with JSON/MD/TOML formatting

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T151344Z.stderr.log`
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
| event:container_stderr     | 98   |

#### container_stderr — top 5 containers by line count
```
     85 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

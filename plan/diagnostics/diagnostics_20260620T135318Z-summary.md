# Forge Diagnostics Summary — 2026-06-20T21:14:27Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T135318Z.log`
- **Forge version**: 0.3.260620.3
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
- cargo-edit
- cargo-tarpaulin
- delve
- hadolint
- pandoc
### Proposed enhancements
- rust: cargo-edit — Enables cargo add/remove/upgrade for dependency management without manual Cargo.toml editing
- rust: cargo-tarpaulin — Code coverage tooling for Rust tests; currently no coverage gating
- go: delve — Go debugger absent despite Go toolchain being installed
- other: hadolint — Dockerfile linter for maintaining the forge container image itself
- other: pandoc — Document format conversion for cheatsheet/doc processing pipelines

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T135318Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
event:container_launch stage=router state=running
event:container_launch stage=router state=starting
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 115   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

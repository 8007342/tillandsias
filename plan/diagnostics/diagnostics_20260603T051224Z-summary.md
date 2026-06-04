# Forge Diagnostics Summary — 2026-06-03T05:13:08Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T051224Z.log`
- **Forge version**: 0.2.260602.7
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
- clangd
- lldb-vscode
- cargo-tarpaulin
- cargo-outdated
### Proposed enhancements
- go: delve — Go debugger needed for debugging Go components in the codebase; no way to set breakpoints or step through Go code without it.
- other: clangd — C/C++ language server for LSP-driven editing of native C/C++ dependencies and FFI bindings; improves code intelligence for mixed-language projects.
- other: lldb-vscode — Debug adapter protocol server for native debugging (C/C++/Rust); enables VSCode/opencode debugging of native code paths.
- rust: cargo-tarpaulin — Rust code coverage tool needed to measure and enforce coverage thresholds in CI; currently no coverage measurement is possible inside the forge.
- rust: cargo-outdated — Rust dependency freshness checker for proactive dependency hygiene; no way to identify stale dependencies without it.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T051224Z.stderr.log`
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
| event:container_stderr     | 126   |

#### container_stderr — top 5 containers by line count
```
    118 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

# Forge Diagnostics Summary — 2026-06-20T12:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T173717Z.log`
- **Forge version**: 0.3.260620.7
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
- clangd
- golangci-lint
- perf
- ripgrep
- fzf
- tmux
- flutter
- zig
- wasmer
### Proposed enhancements
- other: clangd — C/C++ LSP server; required for IDE-grade code intelligence on C/C++ codebases
- go: golangci-lint — Standard Go linter runner; expected in any Go development environment
- other: perf — Linux profiling tool; essential for performance analysis
- other: ripgrep — Fast recursive grep; improves code search ergonomics significantly
- other: fzf — Interactive fuzzy finder; enhances shell workflows
- other: tmux — Terminal multiplexer; critical for persistent remote sessions
- dart: flutter — Dart SDK is present but Flutter SDK is not; blocks Dart/Flutter mobile and desktop development
- wasm: zig — Zig compiler; adjacent to WASM ecosystem, growing relevance for system-level forge work
- wasm: wasmer — Alternative WASM runtime alongside wasmtime; provides broader WASM compatibility testing

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T173717Z.stderr.log`
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
| event:container_stderr     | 102   |

#### container_stderr — top 5 containers by line count
```
     89 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

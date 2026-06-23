# Forge Diagnostics Summary — 2026-06-23T09:06:48Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260623T090550Z.log`
- **Forge version**: 0.3.260623.2
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
- ripgrep
- clangd
- rustup
- tmux
- nix
- protoc
### Proposed enhancements
- go: delve — Go debugger; enables source-level debugging of Go processes in the forge
- other: ripgrep — Fast recursive grep; ubiquitous dev tool significantly faster than grep for code search
- other: clangd — LSP for C/C++/Rust; enables IDE-grade code navigation and completions in forge agent sessions
- rust: rustup — Rust toolchain manager; required to install alternate Rust targets/channels beyond the distro-packaged cargo
- other: tmux — Terminal multiplexer; enables persistent forge sessions and multi-pane workflows during long-running builds
- other: nix — Nix package manager; the project's primary build/dependency system, currently absent from the forge image
- other: protoc — Protobuf compiler; needed for gRPC/protobuf code generation in the Tillandsias build pipeline

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260623T090550Z.stderr.log`
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
| event:container_stderr     | 81   |

#### container_stderr — top 5 containers by line count
```
     71 event:container_stderr container=tillandsias-proxy
     10 event:container_stderr container=tillandsias-git-tillandsias
```

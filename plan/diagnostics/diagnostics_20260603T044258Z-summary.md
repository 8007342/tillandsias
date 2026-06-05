# Forge Diagnostics Summary — 2026-06-03T19:34:21Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T044258Z.log`
- **Forge version**: 0.2.260602.3
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 24 / 25 checks passed (96%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 96%

## Missing Capabilities

- `environment.TILLANDSIAS_CHEATSHEETS`

## Recommended Actions

- Investigate missing capability: environment.TILLANDSIAS_CHEATSHEETS

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- clangd
- clang-tidy
- protoc
- buf
- grpcurl
- flutter
- nix
- tmux
- htop
- netcat
### Proposed enhancements
- other: clangd — C/C++ language server required for LSP support on C/C++ codebases; many Rust projects also use C FFI that benefits from clangd diagnostics
- other: clang-tidy — C/C++ linter complementary to clangd; catches undefined behavior, style violations, and modernizes C/C++ code
- other: protoc — Protocol Buffers compiler widely used across Rust, Go, and Python ecosystems for schema-defined serialization
- other: buf — Protobuf linting, breaking change detection, and BSR integration; standard companion to protoc
- other: grpcurl — gRPC debugging tool essential for testing gRPC services from within the forge without external network
- dart: flutter — FLUTTER_ROOT=/opt/flutter env var is pre-set but flutter binary is absent; completing the SDK installation would enable mobile/desktop UI development
- other: nix — TILLANDSIAS_SHARED_CACHE=/nix/store is pre-configured and nix-first instructions exist but nix binary is absent; installing Nix would honor the existing env setup and instruction set
- other: tmux — Terminal multiplexer expected in development containers for session persistence and split-pane workflows
- other: htop — Interactive process viewer for debugging resource usage during development
- other: netcat — Network debugging utility essential for testing TCP/UDP connectivity from within the isolated forge

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T044258Z.stderr.log`
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
| event:container_stderr     | 227   |

#### container_stderr — top 5 containers by line count
```
    216 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```

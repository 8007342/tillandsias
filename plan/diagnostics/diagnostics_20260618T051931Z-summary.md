# Forge Diagnostics Summary — 2026-06-18T05:19:44Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260618T051931Z.log`
- **Forge version**: 0.3.260618.1
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
- rustup
- delve
- clangd
- gradle
- flutter
### Proposed enhancements
- rust: rustup — CARGO_HOME cache is configured and cargo/rustc present, but no rustup for toolchain version pinning — needed for reproducible CI-local parity
- go: delve — Go toolchain (go, gopls, gofmt) installed, but delve debugger absent — completes the Go development surface
- rust: clangd — gcc/g++ present and Tillandsias uses native C dependencies (via cc crate); clangd provides C/C++ LSP support missing from current LSP roster
- java: gradle — GRADLE_USER_HOME cache path is configured but no gradle binary — cache allocation will be wasted or misrouted
- dart: flutter — Agent instruction file flutter.md exists and dart SDK is at /opt/dart-sdk/bin/dart, but no Flutter SDK — instructions reference a tool not present

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260618T051931Z.stderr.log`
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
| event:container_stderr     | 94   |

#### container_stderr — top 5 containers by line count
```
     86 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

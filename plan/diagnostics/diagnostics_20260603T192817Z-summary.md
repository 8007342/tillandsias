# Forge Diagnostics Summary — 2026-06-03T19:28:31Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T192817Z.log`
- **Forge version**: 0.2.260602.2
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
- flutter
- nix
- protoc
- typos-cli
- sqlite3
- cargo-edit
- cargo-outdated
### Proposed enhancements
- dart: flutter — flutter.md instruction exists and dart SDK is at /opt/dart-sdk, but flutter binary is missing; needed for macOS tray GUI development
- other: nix — nix-first.md instruction exists referencing nix-flake-basics, but nix binary not installed
- other: protoc — multi-language project may need protobuf compilation for gRPC/Rust interop; binary absent
- rust: typos-cli — common CI spell-checker for codebases with multiple languages; absent from image
- other: sqlite3 — universal development utility for quick DB inspection; not installed
- rust: cargo-edit — cargo-add/cargo-rm absent; dependency management without editing Cargo.toml manually
- rust: cargo-outdated — dependency freshness checker for Rust; useful for CI/audit workflows

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T192817Z.stderr.log`
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
| event:container_stderr     | 174   |

#### container_stderr — top 5 containers by line count
```
    166 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

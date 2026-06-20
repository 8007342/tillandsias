# Forge Diagnostics Summary — 2026-06-19T23:44:02Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260619T234257Z.log`
- **Forge version**: 0.3.260619.5
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
- cargo-tarpaulin
- delve
- flutter
- nix
- deno
- bun
- podman
- perf
### Proposed enhancements
- rust: rustup — Enables per-project Rust toolchain pinning; rustc 1.96 is present but version is locked to image.
- dart: flutter — Agent instruction flutter.md exists but Flutter SDK is missing; dart is preinstalled in /opt/dart-sdk.
- other: nix — Agent instruction nix-first.md exists and cheatsheets reference nix-flake-basics.md, but nix is not installed.
- go: delve — Go 1.26 is preinstalled but no debugger; delve enables headless debugging in the sandbox.
- rust: cargo-tarpaulin — Rust coverage tool for CI-quality metrics; cargo-audit and cargo-watch are already present.
- web: deno — Lightweight TypeScript runtime for script-level tooling alongside Node 22.
- other: podman — Container runtime for building/testing images inside the forge without host mounts.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260619T234257Z.stderr.log`
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
| event:container_stderr     | 95   |

#### container_stderr — top 5 containers by line count
```
     82 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

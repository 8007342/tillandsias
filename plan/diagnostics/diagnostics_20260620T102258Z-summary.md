# Forge Diagnostics Summary — 2026-06-20T10:23:41Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T102258Z.log`
- **Forge version**: 0.3.260620.2
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
- flutter
- nix
- podman
- cargo-deny
- cargo-udeps
### Proposed enhancements
- rust: rustup — Rust toolchain management (install/switch channels, components, targets) — rustc/cargo are pre-installed but rustup is absent, preventing on-the-fly channel switching (e.g., nightly for fuzzing) and target addition
- go: delve — Go debugger — gdb is available but delve is the native Go debugger supporting goroutines, core dumps, and headless server mode
- dart: flutter — Flutter SDK — dart is present but flutter SDK is missing; agent instructions reference flutter.md but the toolchain is not installed
- other: nix — Nix package manager — agent instruction nix-first.md exists and cheatsheets reference nix-flake-basics, but nix is not installed, creating a discoverability gap
- other: podman — Container build/test capability within the forge — needed for in-forge container image builds during development (e.g., testing Dockerfiles without external CI)
- rust: cargo-deny — Rust license/compliance checker — standard in Rust CI pipelines for auditing dependency licenses and advisories; complements cargo-audit which is already installed
- rust: cargo-udeps — Detect unused Rust dependencies — keeps Cargo.toml clean; common in Rust CI workflows

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T102258Z.stderr.log`
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
| event:container_stderr     | 99   |

#### container_stderr — top 5 containers by line count
```
     88 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```

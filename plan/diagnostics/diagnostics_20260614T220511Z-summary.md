# Forge Diagnostics Summary — 2026-06-14T22:05:38Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T220511Z.log`
- **Forge version**: 0.3.260614.9
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
- delve (dlv)
- sd
- tokei
- hyperfine
### Proposed enhancements
- rust: rustup — Required for managing Rust toolchains, installing targets (WASI, wasm), and keeping rustc/cargo current. Without it, projects pinned to nightly or specific MSRVs cannot build.
- go: delve (dlv) — First-class Go debugger. Essential for breakpoint debugging and headless CI debugging sessions. Preinstalled gopls but no debugger.
- other: sd — Modern find-and-replace CLI (by @chmln), much faster UX than sed for multi-file patterns. Directly useful in agent scripts and CI pipelines.
- other: tokei — Fast code-statistics tool used in CI/README badges. Currently absent despite ripgrep, fd, and bat being present.
- other: hyperfine — Command-line benchmarking tool. Enables perf regression checks in CI. Companion to cargo-criterion (already installed).
- dart: Flutter SDK — Dart SDK is present at /opt/dart-sdk/bin/dart but Flutter is missing. Agent instructions include flutter.md, suggesting Flutter work is expected.
- other: podman — Missing from inside the forge container. Several forge skills (build-install-and-smoke-test-e2e, smoke-curl-install-and-test-e2e) require podman for E2E container-build workflows.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T220511Z.stderr.log`
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
| event:container_stderr     | 963   |

#### container_stderr — top 5 containers by line count
```
    862 event:container_stderr container=tillandsias-inference
     88 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

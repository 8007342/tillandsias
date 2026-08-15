# Forge Diagnostics Summary — 2026-08-01T06:04:36Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260801T060318Z.log`
- **Forge version**: 0.4.260801.5
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
- clippy
- javac
- flutter
- delve
- golangci-lint
- gofumpt
- bun
### Proposed enhancements
- rust: clippy — cargo and rust-analyzer are preinstalled but the Clippy linter component is absent; a ready-to-use Rust forge needs cargo clippy / cargo fmt check gates for CI parity.
- java: javac (full JDK) — openjdk 25 runtime and Maven are present but javac/gradle/sbt are missing, so JVM builds cannot compile sources.
- dart: flutter — dart-sdk is cached and an opencode flutter.md instruction exists, but the flutter CLI/framework is absent, blocking Dart/Flutter tray UI work.
- go: delve — Go toolchain and gopls are present but there is no Go debugger for interactive service debugging.
- go: golangci-lint — gopls alone covers editor support; golangci-lint (with gofumpt) provides the lint+format gate expected for Go CI.
- go: gofumpt — strict formatter for Go builds; pairs with golangci-lint as a pre-push gate.
- web: bun — node/npm/pnpm are present; bun adds a fast installer/runtime and single-binary JS distribution testing for web services work.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260801T060318Z.stderr.log`
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

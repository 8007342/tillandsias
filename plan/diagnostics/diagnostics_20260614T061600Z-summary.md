# Forge Diagnostics Summary — 2026-06-14T06:13:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T061600Z.log`
- **Forge version**: 0.3.260614.1
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
- delve
- gradle
- flutter
### Proposed enhancements
- rust: clippy — Rust linter essential for Rust development quality; cargo is installed and CARGO_HOME is configured, but clippy is absent
- go: delve — Go debugger complementary to gopls; GOPATH and go binary are present but no debugger is available
- other: gradle — GRADLE_USER_HOME is configured but the Gradle build tool is not installed; JVM projects cannot build
- dart: flutter — Dart SDK is installed at /opt/dart-sdk and flutter.md agent instructions exist, but the flutter CLI is not present — incomplete Dart/Flutter dev environment

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T061600Z.stderr.log`
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
| event:container_stderr     | 185   |

#### container_stderr — top 5 containers by line count
```
    174 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```

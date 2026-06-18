# Forge Diagnostics Summary — 2026-06-17T22:11:43Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260617T221030Z.log`
- **Forge version**: 0.3.260617.3
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
- taplo
- marksman
- yaml-language-server
- flutter
- gradle
### Proposed enhancements
- rust: taplo — TOML language server for editing Cargo.toml and TOML config files; Rust project uses TOML extensively
- other: marksman — Markdown language server for editing documentation and spec files
- other: yaml-language-server — YAML language server for editing workflow and config YAML files
- go: delve — Go debugger; Go toolchain (go, gopls, gofmt) is installed but no debugger available
- dart: flutter — Flutter CLI not installed despite Dart SDK being present; flutter.md instruction exists but no binary
- other: gradle — Java (OpenJDK 25) is installed but no Gradle build tool; GRADLE_USER_HOME is configured

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260617T221030Z.stderr.log`
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
     68 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

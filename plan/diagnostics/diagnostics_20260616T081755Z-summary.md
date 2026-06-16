# Forge Diagnostics Summary — 2026-06-16T08:18:13Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260616T081755Z.log`
- **Forge version**: 0.3.260616.2
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
- flutter
- gradle
### Proposed enhancements
- dart: flutter — Dart SDK 3.12.1 is installed and agent instructions include flutter.md, but flutter binary is absent — adding it completes the Flutter toolchain for Tillandsias frontend work
- go: delve — Go 1.26.4 and gopls are installed but no Go debugger; delve would enable step-debugging Go services in the forge
- java: gradle — Java 25 is installed and GRADLE_USER_HOME is preconfigured, but gradle binary is missing — prevents JVM builds without manual install

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260616T081755Z.stderr.log`
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
| event:container_stderr     | 78   |

#### container_stderr — top 5 containers by line count
```
     70 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

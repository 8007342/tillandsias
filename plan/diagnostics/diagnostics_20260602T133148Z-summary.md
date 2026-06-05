# Forge Diagnostics Summary — 2026-06-02T13:32:31Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260602T133148Z.log`
- **Forge version**: 0.2.260602.1
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
- dcm
### Proposed enhancements
- dart: flutter — Dart SDK is included but Flutter SDK is absent; adding it would enable mobile, desktop, and web UI development from the forge.
- dart: dcm — Dart Code Metrics tool is absent; would provide code quality analysis complementing the existing lint/format toolchain for Dart projects.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260602T133148Z.stderr.log`
- **Total launch events**: 8
- **state=running**: 3
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
```

### Typed-event arms

| event type | count |
|---|---:|
| event:container_stderr     | 129   |

#### container_stderr — top 5 containers by line count
```
    121 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

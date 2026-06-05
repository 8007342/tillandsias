# Forge Diagnostics Summary — 2026-06-03T12:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T221003Z.log`
- **Forge version**: 0.2.260603.1
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
- nix
- flutter
### Proposed enhancements
- other: nix — nix-first.md instruction exists in agent instructions but nix is not installed; required for builds that follow the flake workflow referenced in cache-discipline.md
- dart: flutter — flutter.md instruction exists in agent instructions but Flutter SDK is not installed; Dart SDK is present but Flutter tooling is absent

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T221003Z.stderr.log`
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

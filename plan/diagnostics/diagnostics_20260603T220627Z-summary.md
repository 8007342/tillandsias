# Forge Diagnostics Summary — 2026-06-03T22:07:47Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260603T220627Z.log`
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
- protoc
- tmux
### Proposed enhancements
- other: nix — Nix-first methodology requires it; preinstall to match documented workflow and enable /nix/store sharing
- dart: flutter — Dart SDK is present but Flutter SDK is not; Flutter development instructions exist in agent config
- other: protoc — Common build dependency referenced in nix methodology; likely needed for protobuf compilation
- other: tmux — Common terminal multiplexer expected in dev containers for session persistence

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260603T220627Z.stderr.log`
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
| event:container_stderr     | 207   |

#### container_stderr — top 5 containers by line count
```
    199 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

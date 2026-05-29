# Forge Diagnostics Summary — 2026-05-29T17:12:33Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T171218Z.log`
- **Forge version**: 0.2.260529.4
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
- nix
- nil
### Proposed enhancements
- dart: flutter — flutter.md agent instructions exist but the flutter CLI binary is absent (dart SDK at /opt/dart-sdk/bin/dart is present)
- nix: nix — nix-first.md agent instructions exist but the nix CLI binary is absent
- nix: nil — Nix language server absent; would improve editor/agent navigation of nix expressions referenced in cache-discipline instructions

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T171218Z.stderr.log`
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
| event:container_stderr     | 111   |

#### container_stderr — top 5 containers by line count
```
    103 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

# Forge Diagnostics Summary — 2026-06-01T06:56:36Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260601T065559Z.log`
- **Forge version**: 0.2.260531.3
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
- delve (Go debugger)
- nix (package manager - referenced by nix-first.md but binary absent)
- flutter (Dart SDK present, Flutter SDK absent)
### Proposed enhancements
- go: delve — Go debugger for debugging Go services; Go toolchain is already installed
- other: nix — Nix package manager referenced in forge instructions (nix-first.md) but binary not pre-installed
- dart: flutter — Dart SDK is pre-installed; adding Flutter enables mobile/web UI development without extra setup

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260601T065559Z.stderr.log`
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
| event:container_stderr     | 128   |

#### container_stderr — top 5 containers by line count
```
    120 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

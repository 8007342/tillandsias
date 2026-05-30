# Forge Diagnostics Summary — 2026-05-29T17:09:58Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T170940Z.log`
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
- delve
- lua-language-server
- flutter
### Proposed enhancements
- go: delve — Go debugger is standard for Go development; gopls and go toolchain are present but no debugger
- other: lua-language-server — Common LSP for Lua scripting; no Lua tooling present in the forge
- dart: flutter — Dart SDK 3.12.1 is preinstalled but Flutter SDK is missing; would enable mobile/UI development in the forge

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T170940Z.stderr.log`
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
| event:container_stderr     | 111   |

#### container_stderr — top 5 containers by line count
```
    103 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

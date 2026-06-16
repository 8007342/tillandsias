# Forge Diagnostics Summary — 2026-06-16T18:09:40Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260616T180828Z.log`
- **Forge version**: 0.3.260616.3
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
- clangd
- nix
- flutter
### Proposed enhancements
- go: delve — Go debugger for runtime inspection during forge development
- other: clangd — C/C++ LSP for code completion when forge touches native extensions or system code
- other: nix — Nix package manager referenced by nix-first.md instructions but not installed
- dart: flutter — Flutter SDK referenced by flutter.md instructions; Dart SDK is present but Flutter is not

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260616T180828Z.stderr.log`
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
| event:container_stderr     | 80   |

#### container_stderr — top 5 containers by line count
```
     72 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

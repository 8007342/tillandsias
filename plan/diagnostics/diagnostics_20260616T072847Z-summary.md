# Forge Diagnostics Summary — 2026-06-16T07:29:08Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260616T072847Z.log`
- **Forge version**: 0.3.260616.1
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
- nix
### Proposed enhancements
- dart: flutter — Dart SDK is already installed (v3.10+ at /opt/dart-sdk/bin/dart) but Flutter SDK is absent. Installing Flutter would enable mobile/web UI development in the forge without adding any new language runtime.
- go: delve — Go toolchain (1.26.4) and gopls LSP are present but the standard Go debugger delve is missing. Without it, developers cannot step-debug Go programs inside the forge.
- other: nix — Agent instructions include nix-first.md and cheatsheets reference build/nix-flake-basics.md, but no nix binary is installed. Installing Nix would unlock flake-based builds referenced by the forge's own documentation.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260616T072847Z.stderr.log`
- **Total launch events**: 10
- **state=running**: 4
- **state=failed**: 0

### Distinct stage → state pairings

```
event:container_launch stage=opencode state=exited
event:container_launch stage=opencode state=starting
event:container_launch stage=opencode-git state=running
event:container_launch stage=opencode-git state=starting
event:container_launch stage=opencode-inference state=running
event:container_launch stage=opencode-inference state=starting
event:container_launch stage=opencode-proxy state=running
event:container_launch stage=opencode-proxy state=starting
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

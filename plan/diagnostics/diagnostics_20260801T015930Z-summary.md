# Forge Diagnostics Summary — 2026-08-01T02:14:30Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260801T015930Z.log`
- **Forge version**: 0.4.260730.2
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
- {'tool': 'delve', 'ecosystem': 'go', 'why': 'Go toolchain (go, gopls, gofmt) is present but there is no Go debugger; delve is the standard tool for breakpoint-based Go debugging.'}
- {'tool': 'bun', 'ecosystem': 'web', 'why': 'Node/npm/yarn/pnpm are installed but bun is absent; bun adds a fast all-in-one JS/TS runtime and bundler for web work.'}
- {'tool': 'flutter', 'ecosystem': 'dart', 'why': 'The Dart SDK is preinstalled at /home/forge/.cache/tillandsias-project/dart but the flutter CLI is missing, leaving the Dart toolchain only partially usable.'}
### Proposed enhancements
- go: delve — Install delve (or pre-add the Go debugger) so the preinstalled Go toolchain supports full debugging, not just build/analyze.
- web: bun — Preinstall bun in the forge image to complement node/npm/yarn/pnpm for faster JS/TS scripts and bundling.
- dart: flutter — Preinstall the flutter toolchain to pair with the already-present Dart SDK, making the Dart ecosystem ready-to-use.
- other: cheatsheets — /opt/cheatsheets (TILLANDSIAS_CHEATSHEETS) is an empty 8M tmpfs even though agent instructions @cheatsheet-reference files like runtime/forge-paths-ephemeral-vs-persistent.md; the image should preload actual cheatsheet content (or the instructions should not reference it).

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260801T015930Z.stderr.log`
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

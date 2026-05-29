# Forge Diagnostics Summary — 2026-05-29T09:09:48Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T090935Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- flutter
- wasmtime
### Proposed enhancements
- dart: flutter — FLUTTER_ROOT=/opt/flutter is set in environment but the SDK binary is missing at that path; install Flutter SDK to enable cross-platform mobile development alongside the existing Dart SDK
- wasm: wasmtime — Wasm runtime not installed; would complete the Wasm toolchain (wasm-pack is present) for server-side/edge Wasm execution

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T090935Z.stderr.log`
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
| event:container_stderr     | 125   |

#### container_stderr — top 5 containers by line count
```
    117 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

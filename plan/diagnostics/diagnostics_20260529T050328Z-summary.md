# Forge Diagnostics Summary — 2026-05-29T00:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T050328Z.log`
- **Forge version**: 0.2.260528.1
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- external_curl returned HTTP 403 (not connection refused/timeout) — container can route to external internet through proxy http://proxy:3128; isolation depends entirely on proxy ACL policy

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- flutter (dart SDK installed but flutter binary absent; flutter.md instructions exist)
- nix (nix-first.md instructions exist but nix binary not found)
- wasmtime (wasm-pack installed but no wasm runtime)
- prettier (universal code formatter)
- eslint (JavaScript/TypeScript linter; typescript-language-server present but no linter)
### Proposed enhancements
- dart: flutter — Dart SDK is present and flutter.md instruction exists; installing Flutter completes the Dart/Flutter toolchain
- other: nix — nix-first.md instructions reference Nix workflow patterns; installing nix enables flake-based builds and reproducible environments
- wasm: wasmtime — wasm-pack is installed for building WASM binaries but no runtime exists to execute them; wasmtime fills the gap
- web: prettier — No universal formatter installed; prettier covers JS/TS/CSS/JSON/Markdown formatting used across the project
- web: eslint — typescript-language-server is present but no JS/TS linter; eslint provides linting complementing the LSP

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T050328Z.stderr.log`
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
| event:container_stderr     | 110   |

#### container_stderr — top 5 containers by line count
```
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

# Forge Diagnostics Summary — 2026-05-29T09:25:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T091257Z.log`
- **Forge version**: 0.2.260528.1
- **Host platform**: unknown
- **Agent**: unknown
- **Completeness**: 25 / 25 checks passed (100%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 100%

## Recommended Actions

- All forge capabilities nominal. Consider removing checked items from the diagnostics prompt.

## ⚠️ Isolation / Privacy Risks (investigate before any enhancement)

- External outbound HTTP reaches internet via proxy (example.com returned 403, not BLOCKED); proxy at http://proxy:3128 with custom CA at /etc/tillandsias/ca.crt enables TLS interception of all outbound traffic
- Container overlay storage lives under host user tlatoani's home directory (/home/tlatoani/.local/share/containers/storage/overlay/) — expected container semantics but host can access all container filesystem state

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- delve
- black
- eslint
- prettier
- flutter
- wasm-opt
- wasmtime
- cargo-deny
### Proposed enhancements
- go: delve — Go debugger essential for Go development workflow; Go SDK is installed but debugging is unsupported
- python: black — Standard Python formatter expected in Python-capable forge; Python3 is present but formatting tooling is absent
- web: eslint — JS/TS linting standard; Node is installed but JS toolchain is incomplete
- web: prettier — Universal code formatter across JS/TS/CSS/Markdown; complements existing typescript-language-server
- dart: flutter — flutter.md instruction exists but Flutter SDK is not installed; Dart SDK is present but mobile/desktop/web UI framework missing
- wasm: wasm-opt — Binaryen optimizer for WebAssembly release builds; wasm-pack is installed but optimization pipeline incomplete
- wasm: wasmtime — Standalone Wasm runtime for testing and executing Wasm modules locally
- rust: cargo-deny — License and security advisory checker for Rust dependencies; cargo-audit and cargo-nextest present but deny gap remains

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T091257Z.stderr.log`
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

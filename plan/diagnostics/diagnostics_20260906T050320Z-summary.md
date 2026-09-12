# Forge Diagnostics Summary — 2026-09-06T00:00:00Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260906T050320Z.log`
- **Forge version**: 56.9.5.1
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
- clang
- wasm-bindgen
- binaryen
- nix
- nixd
### Proposed enhancements
- other: delve — Go toolchain ships with the image (GOPATH cache present) but there is no debugger for it; provide delve to close Go debugging in-envelope.
- other: clang — No C frontend beyond the system cc; clang/lld are needed for C-ABI deps and cross-language workflows a ready-to-use forge expects.
- wasm: wasm-bindgen — wasm-pack is preinstalled but the wasm-bindgen companion CLI is absent; install a version-pinned companion so wasm-pack works out of the box.
- wasm: binaryen — provides wasm-opt to shrink/optimize Wasm artifacts in the web/wasm deployment surface, complementing the installed wasm-pack.
- other: nixd — nix-first.md instructions and the nix-flake-basics cheatsheet document nix workflows, but no nix language server is installed to edit flake.nix in-envelope.
- other: nix — cache-discipline references build/nix-flake-basics.md; a single-user nix install inside the existing sandbox makes that documented workflow executable offline.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260906T050320Z.stderr.log`
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

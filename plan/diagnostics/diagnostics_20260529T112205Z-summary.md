# Forge Diagnostics Summary — 2026-05-29T11:22:24Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260529T112205Z.log`
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
- wasm-opt
- taplo
- yaml-language-server
- mold
- nix
- flutter
### Proposed enhancements
- wasm: wasm-opt — Standard WASM optimization tool from binaryen; needed for optimizing WASM output from Rust/LLVM builds
- rust: taplo — TOML language server for editing Cargo.toml and other TOML config files with IDE support
- other: yaml-language-server — YAML language server for editing .yaml methodology, plan, and config files with validation and schema support
- rust: mold — Fast linker that significantly reduces Rust compilation times; widely used in Rust workflows
- other: nix — Nix package manager referenced in flake.nix, nix-first.md instructions, and TILLANDSIAS_SHARED_CACHE but not installed; project expects it
- dart: flutter — Flutter SDK referenced in flutter.md instructions and FLUTTER_ROOT env var but binary absent; instruction file exists but tool is missing

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260529T112205Z.stderr.log`
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
| event:container_stderr     | 973   |

#### container_stderr — top 5 containers by line count
```
    863 event:container_stderr container=tillandsias-inference
    102 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

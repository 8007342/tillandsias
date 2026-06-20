# Forge Diagnostics Summary — 2026-06-20T19:32:17Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260620T161658Z.log`
- **Forge version**: 0.3.260620.4
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
- rustup
- clangd
- clang-format
- lld
- mold
- flutter
- nix
- wasm-opt
- cargo-watch
- cargo-nextest
- cargo-audit
### Proposed enhancements
- other: clangd — C/C++ LSP server needed for IDE-grade code navigation and diagnostics alongside gcc/g++ toolchain
- other: clang-format — C/C++ code formatter expected in a full toolchain environment
- other: llvm (lld, clangd, clang-format) — Install full LLVM/Clang toolchain to provide lld linker, clangd LSP, and clang-format — complements existing gcc/g++
- rust: rustup — Rust toolchain manager enables multi-target cross-compilation and toolchain version management; present rustc is likely installed via rustup but the binary itself is missing from PATH
- rust: mold — Fast linker reduces Rust incremental compile times significantly; standard in Rust dev setups
- rust: cargo-watch — Enables cargo-watch for automatic rebuild/test on file changes during development
- rust: cargo-nextest — Next-generation test runner with better sandboxing, filtering, and output formatting for Rust tests
- rust: cargo-audit — Security vulnerability auditing for Rust dependencies — important for CI/toolchain completeness
- dart: flutter — Agent instruction file flutter.md exists but Flutter SDK is not installed; install to match documented expectations
- other: nix — Agent instruction file nix-first.md exists but nix is not installed; install to enable Nix flake workflows documented in cheatsheets
- wasm: wasm-opt (binaryen) — WASM optimizer missing despite wasmtime and wasm-pack being present; completes the WASM toolchain

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260620T161658Z.stderr.log`
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
| event:container_stderr     | 946   |

#### container_stderr — top 5 containers by line count
```
    847 event:container_stderr container=tillandsias-inference
     86 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```

# Forge Diagnostics Summary — 2026-08-16T10:17:49Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260816T101717Z.log`
- **Forge version**: 0.4.260815.1
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
- javac (JDK present, no compiler; mvn installed but cannot build)
- openssl
- clangd
- clang-format
- libclang
- delve
- flutter
- sccache
### Proposed enhancements
- other: jdk (javac) — Maven (mvn) is preinstalled but only a JRE is present; javac is missing so any Java build fails out of the box.
- other: openssl — The forge ships and mounts CA material (vendor-ca-bundle.crt, /run/tillandsias/ca-chain.crt) yet has no openssl CLI to inspect/test the TLS path.
- rust: clang + libclang + clangd + clang-format — Only GCC is installed; Rust crates using bindgen/clang-sys need libclang, and clangd/clang-format complete the C/C++ LSP+formatter story.
- go: delve — gopls is present but there is no Go debugger for interactive breakpoint workflows.
- dart: flutter — The Dart SDK is already cached but the Flutter SDK is absent, so Dart/Flutter UI work cannot build or run.
- rust: sccache — This is a Rust-heavy forge (tillandsias + wasmtime/wasm-pack built via cargo) with a persistent CARGO_HOME; sccache would accelerate rebuilds within the existing cache envelope.
- rust: rustup — Enables pinned toolchains and components for reproducible builds on top of the present rustc/cargo.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260816T101717Z.stderr.log`
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

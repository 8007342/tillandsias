# Forge Diagnostics Summary — 2026-06-16T13:37:45Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260616T133703Z.log`
- **Forge version**: 0.3.260616.2
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
- flutter
- lua-language-server
- bash-language-server
- yaml-language-server
- clangd
- cargo-tarpaulin
- julia
- dotnet
### Proposed enhancements
- dart: flutter — Dart SDK is present (3.12.1) but flutter binary is missing. Adding Flutter would enable full mobile/web/dev tooling from Dart projects.
- other: lua-language-server — Lua is commonly used for config/plugin files; a language server improves agent editing accuracy for Lua files.
- other: bash-language-server — Bash is used extensively in entrypoints and build scripts; having the LSP available improves agent comprehension of shell code.
- other: yaml-language-server — YAML is used for methodology, plan, and spec files; an LSP improves validation and editing quality.
- other: clangd — C/C++ compilation support exists (rustc depends on system LLVM/clang libraries) but clangd is absent, preventing LSP support for native code.
- rust: cargo-tarpaulin — Code-coverage tool for Rust. cargo-nextest and cargo-criterion are already present; tarpaulin would complete the Rust testing toolkit.

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260616T133703Z.stderr.log`
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
| event:container_stderr     | 78   |

#### container_stderr — top 5 containers by line count
```
     70 event:container_stderr container=tillandsias-proxy
      8 event:container_stderr container=tillandsias-git-tillandsias
```

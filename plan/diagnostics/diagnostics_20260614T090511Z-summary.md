# Forge Diagnostics Summary — 2026-06-14T09:05:39Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T090511Z.log`
- **Forge version**: 0.3.260614.3
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
- clang
- clangd
- rustup
- deno
- bun
- dive
- hadolint
- lua-language-server
### Proposed enhancements
- go: delve — Go debugger — essential for Go development in the forge; gopls is present but no debugger
- dart: flutter — Dart SDK is installed but Flutter framework is absent; flutter.md instructions exist but no binary
- other: clang — C/C++ compiler (gcc present but clang provides better diagnostics and LSP support via clangd)
- other: clangd — C/C++ language server — no LSP available for C/C++ currently
- rust: rustup — Rust toolchain manager — rustc/cargo present but no way to manage toolchains or targets
- web: deno — Alternative JS/TS runtime with native TypeScript, complementary to node
- web: bun — Fast JS/TS runtime and package manager, complementary to node/pnpm/yarn
- other: dive — Container image layer inspection tool — useful when building OCI images in the forge
- other: hadolint — Dockerfile linter — enforces best practices for container image definitions
- other: lua-language-server — Lua LSP — Lua is common in Neovim configs and embedded scripting

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T090511Z.stderr.log`
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
| event:container_stderr     | 114   |

#### container_stderr — top 5 containers by line count
```
    103 event:container_stderr container=tillandsias-proxy
     11 event:container_stderr container=tillandsias-git-tillandsias
```

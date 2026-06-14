# Forge Diagnostics Summary — 2026-06-14T23:07:47Z

## Metadata

- **Source log**: `target/forge-diagnostics/diagnostics_20260614T230648Z.log`
- **Forge version**: 0.3.260614.10
- **Host platform**: linux
- **Agent**: opencode
- **Completeness**: 24 / 25 checks passed (96%)

## Change vs Previous Run

Improvement: completeness rose from 0% to 96%

## Missing Capabilities

- `network_isolation.external_curl`

## Recommended Actions

- Verify enclave network isolation: forge should not reach external internet directly

## Forge Enhancement Candidates (→ curated-toolchain-backlog)

Candidates only — orchestrator approves against the privacy/isolation gate.

### Missing tools
- clang
- clangd
- rustup
- flutter
- gradle
- nix
- fzf
- tmux
- deno
- bun
- dotnet
### Proposed enhancements
- other: clang/clangd — LLVM/Clang toolchain absent alongside GCC; needed for C/C++/ObjC projects and clangd LSP
- dart: flutter — Dart SDK installed and flutter.md agent instruction exists but flutter binary is missing
- other: gradle — GRADLE_USER_HOME cache dir configured but no gradle binary; Java is present
- other: nix — nix-first.md agent instruction exists but nix binary not in PATH
- other: fzf — General shell UX tool for fuzzy search, useful in forge shell sessions
- other: tmux — Terminal multiplexer for persistent/resumable development sessions
- rust: rustup — Rust toolchain version manager; rustc/cargo present but rustup absent for multi-toolchain management

## Container-Start Stream (from .stderr.log companion)

- **Source**: `target/forge-diagnostics/diagnostics_20260614T230648Z.stderr.log`
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
| event:container_stderr     | 957   |

#### container_stderr — top 5 containers by line count
```
    843 event:container_stderr container=tillandsias-inference
    101 event:container_stderr container=tillandsias-proxy
     13 event:container_stderr container=tillandsias-git-tillandsias
```
